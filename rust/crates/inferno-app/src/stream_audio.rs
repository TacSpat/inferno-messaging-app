//! A stream's sound: one app's (the shared window's), or every app's but
//! ours, so viewers never hear the call echoed back to them.
//!
//! PulseAudio (and PipeWire's PulseAudio layer) can record a single
//! playback stream on its own (a "monitor stream" of one sink input). Each
//! app stream we want is recorded that way, and the recordings are mixed
//! into the stream's audio track. Apps that start playing later join the
//! mix; ones that stop leave it.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use livekit::webrtc::audio_frame::AudioFrame;
use livekit::webrtc::audio_source::native::NativeAudioSource;

/// What to hear.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, Default)]
pub enum StreamAudio {
    /// No sound.
    Off,
    /// The shared window's app (screens: every app's, as `Pc`).
    #[default]
    App,
    /// Every app's sound but ours.
    Pc,
    /// The apps ticked in the picker (by name).
    Apps,
}

pub const RATE: u32 = 48_000;
pub const CHANNELS: u32 = 2;
/// 10 ms, WebRTC's frame.
const FRAME: usize = (RATE / 100) as usize;
/// The most each app's recording may run ahead before its oldest sound is
/// dropped (keeps the delay down when an app sends in bursts).
const MAX_BUFFERED: usize = FRAME * 10;

/// Each recorded app's sound (interleaved stereo), by its playback stream.
type Buffers = Arc<Mutex<HashMap<u32, VecDeque<f32>>>>;

/// Recording and mixing; dropping it stops both.
pub struct Capture {
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
    mixer: tokio::task::JoinHandle<()>,
}

impl Drop for Capture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.mixer.abort();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// Whose sound to record.
#[derive(Debug, Clone)]
pub enum Source {
    /// The app owning this X11 window.
    Window(u64),
    /// Every app but ours.
    Pc,
    /// These apps (names as `playing()` gives them).
    Apps(Vec<String>),
}

/// The apps playing sound now (not us), by name, for the picker's list.
/// Blocking (a moment's talk with the sound server).
pub fn playing() -> Vec<String> {
    let me = std::process::id();
    let mut names: Vec<String> = pulse::list().into_iter().filter(|w| !w.pid.is_some_and(|p| descends(p, me))).map(|w| w.name).filter(|n| !n.is_empty()).collect();
    names.sort_by_key(|n| n.to_lowercase());
    names.dedup();
    names
}

/// Starts recording `source` into `out`.
pub fn start(source: Source, out: NativeAudioSource) -> Result<Capture, String> {
    let wanted = match source {
        Source::Window(w) => Want::App(window_pid(w).ok_or("Couldn't tell which app that window belongs to.")?),
        Source::Pc => Want::AllBut(std::process::id()),
        Source::Apps(names) => Want::Named(names, std::process::id()),
    };
    let stop = Arc::new(AtomicBool::new(false));
    let buffers: Buffers = Arc::default();
    let (s, b) = (stop.clone(), buffers.clone());
    let (ready_tx, ready_rx) = std::sync::mpsc::channel();
    let thread = std::thread::Builder::new()
        .name("stream-audio".into())
        .spawn(move || pulse::run(wanted, b, s, ready_tx))
        .map_err(|e| e.to_string())?;
    match ready_rx.recv() {
        Ok(Ok(())) => {}
        Ok(Err(e)) => return Err(e),
        Err(_) => return Err("The sound server stopped.".into()),
    }
    let mixer = tokio::spawn(mix(buffers, out));
    Ok(Capture { stop, thread: Some(thread), mixer })
}

/// Which playback streams to record.
#[derive(Debug, Clone)]
enum Want {
    /// This process's and its children's (browsers play from a helper).
    App(u32),
    /// Everyone's but this process's.
    AllBut(u32),
    /// Apps by name (never ours).
    Named(Vec<String>, u32),
}

/// A playback stream's app.
#[derive(Debug, Clone, Default)]
struct Who {
    pid: Option<u32>,
    /// `application.name` ("Firefox", "spotify").
    name: String,
}

impl Want {
    fn takes(&self, who: &Who) -> bool {
        match (self, who.pid) {
            (Want::App(app), Some(pid)) => descends(pid, *app),
            (Want::App(_), None) => false,
            (Want::AllBut(me), Some(pid)) => !descends(pid, *me),
            (Want::AllBut(_), None) => true,
            (Want::Named(names, me), pid) => !pid.is_some_and(|p| descends(p, *me)) && names.iter().any(|n| *n == who.name),
        }
    }
}

/// Whether `pid` is `ancestor` or one of its descendants.
fn descends(mut pid: u32, ancestor: u32) -> bool {
    for _ in 0..32 {
        if pid == ancestor {
            return true;
        }
        match parent(pid) {
            Some(p) if p > 1 && p != pid => pid = p,
            _ => return false,
        }
    }
    false
}

fn parent(pid: u32) -> Option<u32> {
    let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // "pid (comm) state ppid …": comm may hold spaces and parentheses.
    stat.rsplit_once(')')?.1.split_whitespace().nth(1)?.parse().ok()
}

/// The process that owns an X11 window (`_NET_WM_PID`).
fn window_pid(window: u64) -> Option<u32> {
    use x11rb::connection::Connection;
    use x11rb::protocol::xproto::{AtomEnum, ConnectionExt};
    let (conn, _) = x11rb::connect(None).ok()?;
    let atom = conn.intern_atom(true, b"_NET_WM_PID").ok()?.reply().ok()?.atom;
    let reply = conn.get_property(false, window as u32, atom, AtomEnum::CARDINAL, 0, 1).ok()?.reply().ok()?;
    let pid = reply.value32()?.next();
    conn.flush().ok()?;
    pid
}

/// Every 10 ms: what each app sent, summed, into the track.
async fn mix(buffers: Buffers, out: NativeAudioSource) {
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(10));
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut sum = vec![0f32; FRAME * CHANNELS as usize];
    loop {
        tick.tick().await;
        sum.iter_mut().for_each(|s| *s = 0.0);
        {
            let mut all = buffers.lock().unwrap_or_else(|e| e.into_inner());
            for buffer in all.values_mut() {
                let excess = buffer.len().saturating_sub(MAX_BUFFERED * CHANNELS as usize);
                buffer.drain(..excess);
                for (s, v) in sum.iter_mut().zip(buffer.drain(..buffer.len().min(FRAME * CHANNELS as usize))) {
                    *s += v;
                }
            }
        }
        let data: Vec<i16> = sum.iter().map(|s| (s.clamp(-1.0, 1.0) * 32767.0) as i16).collect();
        let frame = AudioFrame { data: data.into(), sample_rate: RATE, num_channels: CHANNELS, samples_per_channel: FRAME as u32 };
        if out.capture_frame(&frame).await.is_err() {
            break;
        }
    }
}

mod pulse {
    //! The recording side, on its own thread (libpulse objects stay on
    //! the thread that made them).

    use std::cell::RefCell;
    use std::collections::HashMap;
    use std::rc::Rc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    use libpulse_binding as pa;
    use pa::callbacks::ListResult;
    use pa::context::introspect::SinkInputInfo;
    use pa::context::subscribe::{Facility, InterestMaskSet, Operation};
    use pa::context::{Context, FlagSet as ContextFlags, State};
    use pa::def::BufferAttr;
    use pa::mainloop::standard::Mainloop;
    use pa::sample::{Format, Spec};
    use pa::stream::{FlagSet as StreamFlags, PeekResult, Stream};
    use pa::time::MicroSeconds;

    use super::{Buffers, Want, Who, CHANNELS, FRAME, RATE};

    enum Seen {
        /// A playback stream (index, its app).
        Playing(u32, Who),
        /// Look this one up.
        Check(u32),
        Gone(u32),
    }

    fn who(i: &SinkInputInfo) -> Who {
        let pid = i.proplist.get_str("application.process.id").and_then(|p| p.parse().ok());
        let name = i.proplist.get_str("application.name").unwrap_or_default();
        Who { pid, name }
    }

    fn info(i: &SinkInputInfo) -> Seen {
        Seen::Playing(i.index, who(i))
    }

    /// Connected, or `None`.
    fn connect() -> Option<(Mainloop, Context)> {
        let mut ml = Mainloop::new()?;
        let mut ctx = Context::new(&ml, "Inferno")?;
        ctx.connect(None, ContextFlags::NOAUTOSPAWN, None).ok()?;
        loop {
            match ctx.get_state() {
                State::Ready => return Some((ml, ctx)),
                State::Failed | State::Terminated => return None,
                _ => {
                    if !turn(&mut ml) {
                        return None;
                    }
                }
            }
        }
    }

    /// Every playback stream's app, now.
    pub(super) fn list() -> Vec<Who> {
        let Some((mut ml, ctx)) = connect() else { return Vec::new() };
        let out: Rc<RefCell<(Vec<Who>, bool)>> = Rc::default();
        let o = out.clone();
        ctx.introspect().get_sink_input_info_list(move |r| match r {
            ListResult::Item(i) => o.borrow_mut().0.push(who(i)),
            _ => o.borrow_mut().1 = true,
        });
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while !out.borrow().1 && std::time::Instant::now() < deadline && turn(&mut ml) {}
        let list = std::mem::take(&mut out.borrow_mut().0);
        list
    }

    /// Spins the loop once, waiting up to 20 ms for something to happen.
    fn turn(ml: &mut Mainloop) -> bool {
        ml.prepare(Some(MicroSeconds(20_000))).is_ok() && ml.poll().is_ok() && ml.dispatch().is_ok()
    }

    pub(super) fn run(want: Want, buffers: Buffers, stop: Arc<AtomicBool>, ready: std::sync::mpsc::Sender<Result<(), String>>) {
        let fail = |e: &str| {
            let _ = ready.send(Err(e.to_owned()));
        };
        let Some((mut ml, mut ctx)) = connect() else { return fail("Couldn't reach the sound server.") };
        let seen: Rc<RefCell<Vec<Seen>>> = Rc::default();
        let s = seen.clone();
        ctx.set_subscribe_callback(Some(Box::new(move |facility, op, index| {
            if facility == Some(Facility::SinkInput) {
                match op {
                    Some(Operation::New) => s.borrow_mut().push(Seen::Check(index)),
                    Some(Operation::Removed) => s.borrow_mut().push(Seen::Gone(index)),
                    _ => {}
                }
            }
        })));
        ctx.subscribe(InterestMaskSet::SINK_INPUT, |_| {});
        let s = seen.clone();
        ctx.introspect().get_sink_input_info_list(move |r| {
            if let ListResult::Item(i) = r {
                s.borrow_mut().push(info(i));
            }
        });
        let _ = ready.send(Ok(()));

        let spec = Spec { format: Format::F32le, rate: RATE, channels: CHANNELS as u8 };
        // Small pieces (10 ms) so the mix stays close behind the apps.
        let attr = BufferAttr { maxlength: u32::MAX, tlength: u32::MAX, prebuf: u32::MAX, minreq: u32::MAX, fragsize: (FRAME * CHANNELS as usize * 4) as u32 };
        let mut streams: HashMap<u32, Stream> = HashMap::new();
        while !stop.load(Ordering::Relaxed) {
            if !turn(&mut ml) || matches!(ctx.get_state(), State::Failed | State::Terminated) {
                break;
            }
            let events: Vec<Seen> = seen.borrow_mut().drain(..).collect();
            for event in events {
                match event {
                    Seen::Check(index) => {
                        let s = seen.clone();
                        ctx.introspect().get_sink_input_info(index, move |r| {
                            if let ListResult::Item(i) = r {
                                s.borrow_mut().push(info(i));
                            }
                        });
                    }
                    Seen::Playing(index, who) if want.takes(&who) && !streams.contains_key(&index) => {
                        let Some(mut stream) = Stream::new(&mut ctx, "Inferno stream audio", &spec, None) else { continue };
                        if stream.set_monitor_stream(index).is_err() || stream.connect_record(None, Some(&attr), StreamFlags::ADJUST_LATENCY | StreamFlags::DONT_MOVE).is_err() {
                            continue;
                        }
                        streams.insert(index, stream);
                    }
                    Seen::Playing(..) => {}
                    Seen::Gone(index) => {
                        if let Some(mut stream) = streams.remove(&index) {
                            let _ = stream.disconnect();
                        }
                        buffers.lock().unwrap_or_else(|e| e.into_inner()).remove(&index);
                    }
                }
            }
            // What each recording has, into its buffer.
            let mut all = buffers.lock().unwrap_or_else(|e| e.into_inner());
            for (index, stream) in streams.iter_mut() {
                if stream.get_state() != pa::stream::State::Ready {
                    continue;
                }
                loop {
                    match stream.peek() {
                        Ok(PeekResult::Data(bytes)) => {
                            let buffer = all.entry(*index).or_default();
                            buffer.extend(bytes.chunks_exact(4).map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]])));
                            let _ = stream.discard();
                        }
                        Ok(PeekResult::Hole(_)) => {
                            let _ = stream.discard();
                        }
                        _ => break,
                    }
                }
            }
        }
        for (_, mut stream) in streams {
            let _ = stream.disconnect();
        }
        ctx.disconnect();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn our_own_process_is_left_out() {
        let me = std::process::id();
        let at = |pid: Option<u32>, name: &str| Who { pid, name: name.into() };
        assert!(!Want::AllBut(me).takes(&at(Some(me), "")));
        assert!(Want::AllBut(me).takes(&at(Some(1), "")));
        assert!(Want::App(me).takes(&at(Some(me), "")));
        assert!(!Want::App(me).takes(&at(None, "")));
        // Ticked apps by name; never ours, even under a ticked name.
        let named = Want::Named(vec!["spotify".into()], me);
        assert!(named.takes(&at(Some(1), "spotify")));
        assert!(!named.takes(&at(Some(1), "Firefox")));
        assert!(!named.takes(&at(Some(me), "spotify")));
        // Our parent isn't one of ours.
        let parent = parent(me).unwrap();
        assert!(!descends(parent, me));
        assert!(descends(me, parent));
    }
}
