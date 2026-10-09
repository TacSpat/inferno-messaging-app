//! Sharing our screen or a window (Rails' Share Screen and its Screen Share
//! Settings: resolution, frame rate, smoothness or clarity). WebRTC's own
//! desktop capturer grabs it (X11 here); each frame is turned into I420,
//! scaled down to the chosen size and handed to the published track, and
//! a copy goes to `calls::FRAMES` so we see what we send.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use livekit::webrtc::desktop_capturer::{CaptureSource, DesktopCaptureSourceType, DesktopCapturer, DesktopCapturerOptions, DesktopFrame};
use livekit::webrtc::native::yuv_helper;
use livekit::webrtc::video_frame::{I420Buffer, VideoBuffer, VideoFrame, VideoRotation};
use livekit::webrtc::video_source::native::NativeVideoSource;

use crate::calls::{Frame, Pixels, VideoKind, FRAMES, GPU_VIDEO};

/// Rails' picker, remembered (Rails kept it in localStorage).
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
#[serde(default)]
pub struct ShareSettings {
    /// 480, 720, 1080, 1440 or 2160 (4K).
    pub height: u32,
    /// 15, 30 or 60.
    pub fps: u32,
    /// Rails' "Prefer Clarity": a sharper picture at no more than 15 fps.
    pub clarity: bool,
}

impl Default for ShareSettings {
    fn default() -> Self {
        Self { height: 1080, fps: 30, clarity: false }
    }
}

impl ShareSettings {
    /// What is actually sent: clarity caps the frame rate as Rails did.
    pub fn frame_rate(&self) -> u32 {
        if self.clarity {
            self.fps.min(15)
        } else {
            self.fps
        }
    }

    /// The most bits a second the encoder may use: by size, scaled for the
    /// frame rate (a still screen costs far less; this is the ceiling).
    pub fn bitrate(&self) -> u64 {
        let at30: u64 = match self.height {
            0..=480 => 1_200_000,
            481..=720 => 2_500_000,
            721..=1080 => 4_500_000,
            1081..=1440 => 8_000_000,
            _ => 14_000_000,
        };
        at30 * (self.frame_rate() as u64 + 30) / 60
    }
}

/// The picker's state (Rails' Screen Share Settings).
#[derive(Default)]
pub struct Picker {
    /// `None` while still looking.
    pub sources: Option<Vec<Source>>,
    /// The Windows tab (else Screens).
    pub windows: bool,
    /// (window, id) picked.
    pub pick: Option<(bool, u64)>,
    pub settings: ShareSettings,
    /// Each source's picture, by its slot in `shown()`.
    pub thumbs: Vec<Option<makepad_widgets::Texture>>,
}

impl Picker {
    /// The sources on the current tab.
    pub fn shown(&self) -> Vec<&Source> {
        self.sources.iter().flatten().filter(|s| s.window == self.windows).collect()
    }
}

/// Something that can be shared.
#[derive(Debug, Clone)]
pub struct Source {
    pub window: bool,
    pub id: u64,
    pub title: String,
    /// A small picture of it: (width, height, BGRA).
    pub thumb: Option<(usize, usize, Vec<u32>)>,
}

/// The size a `w`×`h` picture is sent at: within `height` lines (and its
/// 16:9 width), never larger than it is, both even.
pub fn fit(w: u32, h: u32, height: u32) -> (u32, u32) {
    let (bw, bh) = (height * 16 / 9, height);
    let k = (bw as f64 / w as f64).min(bh as f64 / h as f64).min(1.0);
    let even = |x: f64| ((x.round() as u32) & !1).max(2);
    (even(w as f64 * k), even(h as f64 * k))
}

fn capturer(window: bool) -> Option<DesktopCapturer> {
    let mut options = DesktopCapturerOptions::new(if window { DesktopCaptureSourceType::Window } else { DesktopCaptureSourceType::Screen });
    options.set_include_cursor(true);
    DesktopCapturer::new(options)
}

/// One frame of `source`, now (for its thumbnail).
fn grab(window: bool, source: CaptureSource) -> Option<(usize, usize, Vec<u32>)> {
    let mut c = capturer(window)?;
    let out = Arc::new(std::sync::Mutex::new(None));
    let o = out.clone();
    c.start_capture(Some(source), move |r| {
        if let Ok(frame) = r {
            *o.lock().unwrap_or_else(|e| e.into_inner()) = thumbnail(&frame);
        }
    });
    // The first capture of a window can come back empty while it's set up.
    for _ in 0..3 {
        c.capture_frame();
        if out.lock().unwrap_or_else(|e| e.into_inner()).is_some() {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(30));
    }
    let t = out.lock().unwrap_or_else(|e| e.into_inner()).take();
    t
}

/// A frame shrunk to fit 320×180 (nearest pixel: it's a preview).
fn thumbnail(frame: &DesktopFrame) -> Option<(usize, usize, Vec<u32>)> {
    let (w, h, stride) = (frame.width().max(0) as usize, frame.height().max(0) as usize, frame.stride() as usize);
    if w == 0 || h == 0 {
        return None;
    }
    let k = (320.0 / w as f64).min(180.0 / h as f64).min(1.0);
    let (tw, th) = (((w as f64 * k) as usize).max(1), ((h as f64 * k) as usize).max(1));
    let data = frame.data();
    let mut out = Vec::with_capacity(tw * th);
    for y in 0..th {
        let row = (y * h / th) * stride;
        for x in 0..tw {
            let i = row + (x * w / tw) * 4;
            let px = data.get(i..i + 4)?;
            out.push(u32::from_le_bytes([px[0], px[1], px[2], 0xff]));
        }
    }
    Some((tw, th, out))
}

/// Every screen and window there is to share, with a picture of each.
/// Blocking (it captures each once).
pub fn sources() -> Vec<Source> {
    let mut all = Vec::new();
    for window in [false, true] {
        let Some(c) = capturer(window) else { continue };
        let list = c.get_source_list();
        drop(c);
        let screens = list.len();
        for (i, s) in list.into_iter().enumerate() {
            let title = s.title();
            if window && title.trim().is_empty() {
                continue;
            }
            let title = if window {
                title
            } else if screens == 1 {
                "Entire Screen".to_owned()
            } else {
                format!("Screen {}", i + 1)
            };
            let id = s.id();
            all.push(Source { window, id, title, thumb: grab(window, s) });
        }
    }
    all
}

/// A share running on its own thread; dropping it stops the capture.
pub struct Capture {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Starts capturing `window`/`id` into `out` at `settings`; our own copy
/// goes into `FRAMES` under `me`. `ended` is called if the source goes
/// away (a closed window).
pub fn start(window: bool, id: u64, settings: ShareSettings, out: NativeVideoSource, me: String, ended: impl FnOnce() + Send + 'static) -> Result<Capture, String> {
    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();
    let thread = std::thread::Builder::new()
        .name("screen-share".into())
        .spawn(move || {
            let Some(mut c) = capturer(window) else {
                let _ = ready_tx.send(Err("Screen capture isn't available here.".into()));
                return;
            };
            let Some(source) = c.get_source_list().into_iter().find(|x| x.id() == id) else {
                let _ = ready_tx.send(Err("That screen or window is gone.".into()));
                return;
            };
            let _ = ready_tx.send(Ok(()));
            let failed = Arc::new(AtomicBool::new(false));
            let f = failed.clone();
            let height = settings.height;
            let mut seq = 0u64;
            let mut last_preview = std::time::Instant::now() - std::time::Duration::from_secs(1);
            let mut rate = crate::calls::Rate::new();
            let epoch = std::time::Instant::now();
            c.start_capture(Some(source), move |r| {
                let frame = match r {
                    Ok(frame) => frame,
                    Err(livekit::webrtc::desktop_capturer::CaptureError::Permanent) => {
                        f.store(true, Ordering::Relaxed);
                        return;
                    }
                    Err(_) => return,
                };
                let started = std::time::Instant::now();
                let Some(buffer) = to_i420(&frame, height) else { return };
                if let Some(r) = rate.as_mut() {
                    r.tick(&format!("sending {}x{} from {}x{} (convert {:?})", buffer.width(), buffer.height(), frame.width(), frame.height(), started.elapsed()));
                }
                // What we see: 15 times a second is plenty for a preview.
                if last_preview.elapsed() >= std::time::Duration::from_millis(66) {
                    last_preview = std::time::Instant::now();
                    seq += 1;
                    preview(&me, &buffer, seq);
                }
                // What we send.
                // When it was captured: WebRTC paces the encoder by these.
                let timestamp_us = epoch.elapsed().as_micros() as i64;
                out.capture_frame(&VideoFrame { rotation: VideoRotation::VideoRotation0, timestamp_us, frame_metadata: None, buffer });
            });
            let period = std::time::Duration::from_secs_f64(1.0 / settings.frame_rate().max(1) as f64);
            let mut next = std::time::Instant::now();
            while !s.load(Ordering::Relaxed) {
                c.capture_frame();
                if failed.load(Ordering::Relaxed) {
                    ended();
                    return;
                }
                next += period;
                let now = std::time::Instant::now();
                if next > now {
                    std::thread::sleep(next - now);
                } else {
                    next = now;
                }
            }
        })
        .map_err(|e| e.to_string())?;
    match ready_rx.recv() {
        Ok(Ok(())) => Ok(Capture { stop, thread: Some(thread) }),
        Ok(Err(e)) => Err(e),
        Err(_) => Err("Screen capture stopped.".into()),
    }
}

/// A captured frame as I420 at the size it's sent.
fn to_i420(frame: &DesktopFrame, height: u32) -> Option<I420Buffer> {
    let (w, h) = (frame.width(), frame.height());
    if w <= 1 || h <= 1 {
        return None;
    }
    // I420 wants even sizes: the odd last row or column is dropped.
    let (w, h) = ((w & !1) as u32, (h & !1) as u32);
    let mut full = I420Buffer::new(w, h);
    let (sy, su, sv) = full.strides();
    let (y, u, v) = full.data_mut();
    yuv_helper::argb_to_i420(frame.data(), frame.stride(), y, sy, u, su, v, sv, w as i32, h as i32);
    let (tw, th) = fit(w, h, height);
    Some(if (tw, th) == (w, h) { full } else { full.scale(tw as i32, th as i32) })
}

/// Our own stream, for us to see.
fn preview(me: &str, buffer: &I420Buffer, seq: u64) {
    let (w, h) = (buffer.width() as usize, buffer.height() as usize);
    let (y, u, v) = buffer.data();
    let (sy, su, sv) = buffer.strides();
    let pixels = if GPU_VIDEO.load(Ordering::Relaxed) {
        crate::calls::i420_pixels(w, h, (y, u, v), (sy as usize, su as usize, sv as usize))
    } else {
        let mut out = vec![0u32; w * h];
        // SAFETY: a u32 slice viewed as its bytes, same length × 4.
        let bytes = unsafe { std::slice::from_raw_parts_mut(out.as_mut_ptr() as *mut u8, w * h * 4) };
        yuv_helper::i420_to_argb(y, sy, u, su, v, sv, bytes, (w * 4) as u32, w as i32, h as i32);
        Pixels::Bgra(out)
    };
    FRAMES
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get_or_insert_with(Default::default)
        .insert((me.to_owned(), VideoKind::Screen), Frame { width: w, height: h, pixels: Some(pixels), seq, at: std::time::Instant::now() });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fits_within_the_chosen_size() {
        assert_eq!(fit(3840, 2160, 1080), (1920, 1080));
        assert_eq!(fit(1280, 720, 1080), (1280, 720));
        // Ultrawide: limited by width.
        assert_eq!(fit(3440, 1440, 720), (1280, 536));
        // A tall window: limited by height.
        assert_eq!(fit(801, 1201, 480), (320, 480));
    }

    #[test]
    fn clarity_caps_the_frame_rate() {
        let s = ShareSettings { height: 1080, fps: 60, clarity: true };
        assert_eq!(s.frame_rate(), 15);
        assert!(s.bitrate() < ShareSettings { clarity: false, ..s.clone() }.bitrate());
    }
}
