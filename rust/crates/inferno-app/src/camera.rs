//! Our camera while it's on in a call (Rails' camera button). Makepad
//! opens the device (V4L2 here); each frame becomes I420 at most 720p and
//! goes to `calls::camera_frame`, which sends it and shows it on our card.
//! The camera is open only while it's on: turning it off closes it.

use makepad_widgets::*;

use livekit::webrtc::native::yuv_helper;
use livekit::webrtc::video_frame::{I420Buffer, VideoBuffer};

/// What we aim for: 720p, at least 24 frames a second.
const MAX_W: usize = 1280;
const MAX_H: usize = 720;
const MIN_FPS: f64 = 24.0;

#[derive(Default)]
pub struct Camera {
    /// Every camera: (id, name, formats).
    devices: Vec<VideoInputDesc>,
    installed: bool,
    on: bool,
}

impl Camera {
    pub fn handle_event(&mut self, cx: &mut Cx, event: &Event) {
        if let Event::VideoInputs(inputs) = event {
            self.devices = inputs.descs.clone();
            if self.on {
                self.open(cx);
            }
        }
    }

    /// Opens or closes the camera (a test run never opens one: its frames
    /// come from a pattern).
    pub fn set_on(&mut self, cx: &mut Cx, on: bool) {
        if on == self.on {
            return;
        }
        self.on = on;
        if std::env::var_os("INFERNO_FAKE_VIDEO").is_some() {
            return;
        }
        if on {
            if !self.installed {
                self.installed = true;
                cx.video_input(0, |frame| {
                    if crate::calls::camera_live() {
                        if let Some(buffer) = to_i420(&frame) {
                            crate::calls::camera_frame(buffer);
                        }
                    }
                });
            }
            self.open(cx);
        } else {
            cx.use_video_input(&[]);
        }
    }

    fn open(&self, cx: &mut Cx) {
        let Some(device) = self.devices.first() else { return };
        if let Some(format) = pick(&device.formats) {
            cx.use_video_input(&[(device.input_id, format.format_id)]);
        }
    }
}

/// The format to capture in: the most pixels up to 720p at a smooth frame
/// rate, uncompressed when it ties (no decoding); otherwise the fastest.
fn pick(formats: &[VideoFormat]) -> Option<VideoFormat> {
    let usable = |f: &&VideoFormat| !matches!(f.pixel_format, VideoPixelFormat::Unsupported(_) | VideoPixelFormat::GRAY);
    let smooth = |f: &&VideoFormat| f.frame_rate.is_none_or(|r| r >= MIN_FPS) && f.width <= MAX_W && f.height <= MAX_H;
    let raw = |f: &VideoFormat| !matches!(f.pixel_format, VideoPixelFormat::MJPEG);
    formats
        .iter()
        .filter(usable)
        .filter(smooth)
        .max_by_key(|f| (f.width * f.height, raw(f)))
        .or_else(|| formats.iter().filter(usable).max_by(|a, b| a.frame_rate.unwrap_or(0.0).total_cmp(&b.frame_rate.unwrap_or(0.0))))
        .copied()
}

/// A camera frame as I420, scaled down to fit 720p.
fn to_i420(frame: &VideoBufferRef) -> Option<I420Buffer> {
    let (w, h) = (frame.format.width, frame.format.height);
    if w < 2 || h < 2 {
        return None;
    }
    let bytes: &[u8] = match &frame.data {
        VideoBufferRefData::U8(b) => b,
        // SAFETY: the u32 words viewed as their bytes.
        VideoBufferRefData::U32(w) => unsafe { std::slice::from_raw_parts(w.as_ptr() as *const u8, w.len() * 4) },
    };
    let mut out = match frame.format.pixel_format {
        VideoPixelFormat::YUY2 => yuy2(bytes, w, h)?,
        VideoPixelFormat::NV12 => {
            let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
            let (y, uv) = bytes.split_at_checked(w * h)?;
            let uv = uv.get(..cw * ch * 2)?;
            let mut b = I420Buffer::new(w as u32, h as u32);
            let (sy, su, sv) = b.strides();
            let (dy, du, dv) = b.data_mut();
            yuv_helper::nv12_to_i420(y, w as u32, uv, (cw * 2) as u32, dy, sy, du, su, dv, sv, w as i32, h as i32);
            b
        }
        VideoPixelFormat::YUV420 => {
            let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
            let mut b = I420Buffer::new(w as u32, h as u32);
            let (sy, su, _) = b.strides();
            let (dy, du, dv) = b.data_mut();
            let (y, rest) = bytes.split_at_checked(w * h)?;
            let (u, v) = rest.split_at_checked(cw * ch)?;
            let v = v.get(..cw * ch)?;
            for row in 0..h {
                dy[row * sy as usize..][..w].copy_from_slice(&y[row * w..][..w]);
            }
            for row in 0..ch {
                du[row * su as usize..][..cw].copy_from_slice(&u[row * cw..][..cw]);
                dv[row * su as usize..][..cw].copy_from_slice(&v[row * cw..][..cw]);
            }
            b
        }
        VideoPixelFormat::RGB24 => {
            // libyuv takes 4 bytes a pixel: widen to RGBA first.
            let rgba: Vec<u8> = bytes.get(..w * h * 3)?.chunks_exact(3).flat_map(|p| [p[0], p[1], p[2], 255]).collect();
            rgba_to_i420(&rgba, w, h)
        }
        VideoPixelFormat::MJPEG => mjpeg(bytes)?,
        _ => return None,
    };
    let (ow, oh) = (out.width(), out.height());
    let (tw, th) = crate::share::fit(ow, oh, MAX_H as u32);
    Some(if (tw, th) == (ow, oh) { out } else { out.scale(tw as i32, th as i32) })
}

/// RGBA bytes as I420 (libyuv's "ABGR" is RGBA in memory).
fn rgba_to_i420(rgba: &[u8], w: usize, h: usize) -> I420Buffer {
    let mut b = I420Buffer::new(w as u32, h as u32);
    let (sy, su, sv) = b.strides();
    let (dy, du, dv) = b.data_mut();
    yuv_helper::abgr_to_i420(rgba, (w * 4) as u32, dy, sy, du, su, dv, sv, w as i32, h as i32);
    b
}

/// YUY2 (Y0 U Y1 V) as I420: chroma from each pair of rows averaged.
fn yuy2(bytes: &[u8], w: usize, h: usize) -> Option<I420Buffer> {
    let w = w & !1;
    let stride = w * 2;
    let src = bytes.get(..stride * h)?;
    let mut b = I420Buffer::new(w as u32, h as u32);
    let (sy, su, sv) = b.strides();
    let (dy, du, dv) = b.data_mut();
    for row in 0..h {
        let line = &src[row * stride..][..stride];
        let out = &mut dy[row * sy as usize..][..w];
        for (x, px) in out.iter_mut().enumerate() {
            *px = line[x * 2];
        }
    }
    for row in 0..h.div_ceil(2) {
        let a = &src[(row * 2) * stride..][..stride];
        let b2 = &src[((row * 2 + 1).min(h - 1)) * stride..][..stride];
        for x in 0..w / 2 {
            du[row * su as usize + x] = ((a[x * 4 + 1] as u16 + b2[x * 4 + 1] as u16 + 1) / 2) as u8;
            dv[row * sv as usize + x] = ((a[x * 4 + 3] as u16 + b2[x * 4 + 3] as u16 + 1) / 2) as u8;
        }
    }
    Some(b)
}

/// A webcam's JPEG frame, decoded.
fn mjpeg(bytes: &[u8]) -> Option<I420Buffer> {
    use zune_jpeg::zune_core::bytestream::ZCursor;
    use zune_jpeg::zune_core::colorspace::ColorSpace;
    use zune_jpeg::zune_core::options::DecoderOptions;
    let options = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGBA);
    let mut decoder = zune_jpeg::JpegDecoder::new_with_options(ZCursor::new(bytes), options);
    let rgba = decoder.decode().ok()?;
    let (w, h) = decoder.dimensions()?;
    (rgba.len() >= w * h * 4 && w >= 2 && h >= 2).then(|| rgba_to_i420(&rgba, w, h))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fmt(w: usize, h: usize, fps: f64, pixel_format: VideoPixelFormat) -> VideoFormat {
        VideoFormat { format_id: VideoFormatId(LiveId::from_str(&format!("{w}x{h}{fps}{pixel_format:?}"))), width: w, height: h, frame_rate: Some(fps), pixel_format }
    }

    #[test]
    fn picks_smooth_720p() {
        // A USB 2 camera: raw 720p only at 10 fps, MJPEG at 30.
        let formats = [
            fmt(640, 480, 30.0, VideoPixelFormat::YUY2),
            fmt(1280, 720, 10.0, VideoPixelFormat::YUY2),
            fmt(1280, 720, 30.0, VideoPixelFormat::MJPEG),
            fmt(1920, 1080, 30.0, VideoPixelFormat::MJPEG),
        ];
        let f = pick(&formats).unwrap();
        assert_eq!((f.width, f.height, f.pixel_format), (1280, 720, VideoPixelFormat::MJPEG));
        // Raw wins a tie.
        let formats = [fmt(1280, 720, 30.0, VideoPixelFormat::MJPEG), fmt(1280, 720, 30.0, VideoPixelFormat::YUY2)];
        assert_eq!(pick(&formats).unwrap().pixel_format, VideoPixelFormat::YUY2);
    }

    #[test]
    fn yuy2_converts() {
        // 2×2: Y 10 20 / 30 40, U 100/120 → 110, V 200/220 → 210.
        let px = [10, 100, 20, 200, 30, 120, 40, 220];
        let b = yuy2(&px, 2, 2).unwrap();
        let (y, u, v) = b.data();
        assert_eq!((y[0], y[1], u[0], v[0]), (10, 20, 110, 210));
        assert_eq!(y[b.strides().0 as usize..][..2], [30, 40]);
    }
}
