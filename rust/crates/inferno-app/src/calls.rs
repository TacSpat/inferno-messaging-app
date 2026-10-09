//! The call itself: a LiveKit room for the voice channel we're in. WebRTC
//! runs the microphone and speakers (LiveKit's platform audio), so its echo
//! cancellation hears what the speakers play; noise suppression and gain
//! control are WebRTC's too.
//!
//! - Mute mutes our published microphone track; deafen turns every remote
//!   audio track off (and mutes, as Rails does).
//! - Who is speaking is measured from the audio we receive, as Rails did
//!   (an analyser per remote voice): each incoming track is tapped and its
//!   level (RMS, smoothed Rails' way) written to `LEVELS` for the UI.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use livekit::options::{TrackPublishOptions, VideoCodec};
use livekit::prelude::*;
use livekit::webrtc::audio_frame::AudioFrame;
use livekit::webrtc::audio_source::native::NativeAudioSource;
use livekit::webrtc::audio_source::{AudioSourceOptions, RtcAudioSource};
use livekit::{AudioProcessingOptions, PlatformAudio};
use makepad_widgets::Cx;

use crate::backend::Update;

/// How loud each voice we receive is, by LiveKit identity (a pubkey's
/// first 12 hex digits): the smoothed RMS and when it was measured (a
/// voice that stops arriving, muted or gone, reads as silent).
pub static LEVELS: Mutex<Option<HashMap<String, (f32, std::time::Instant)>>> = Mutex::new(None);

#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub enum CallState {
    #[default]
    Idle,
    Connecting,
    Connected,
    Reconnecting,
}

/// Audio processing the user chose (Rails' Voice & Video page).
#[derive(Debug, Clone, PartialEq)]
pub struct Processing {
    pub echo_cancellation: bool,
    pub noise_suppression: bool,
    pub auto_gain_control: bool,
    /// Devices by name (`None`: the system's default).
    pub input: Option<String>,
    pub output: Option<String>,
}

struct Live {
    room: Arc<Room>,
    mic: LocalAudioTrack,
    /// The devices (none in a fake-mic test run).
    _audio: Option<PlatformAudio>,
    events: tokio::task::JoinHandle<()>,
    deaf: Arc<std::sync::atomic::AtomicBool>,
    /// Other rooms heard listen-only, by channel: the hearths above (their
    /// broadcasters), and embers below with someone let up.
    relays: HashMap<String, (Arc<Room>, tokio::task::JoinHandle<()>)>,
    /// Our screen share: the capture and its published track.
    share: Option<(crate::share::Capture, livekit::id::TrackSid)>,
}

#[derive(Default)]
pub struct Calls {
    live: Option<Live>,
    /// Who in the other rooms is heard (LiveKit identities): broadcasters
    /// above, people let up from below.
    broadcasters: Arc<Mutex<std::collections::HashSet<String>>>,
    /// Per-person volume and mute-for-me (Voice & Video prefs).
    people: Arc<Mutex<People>>,
    /// The streams we're watching (LiveKit identities).
    watching: Arc<Mutex<std::collections::HashSet<String>>>,
}

/// A hearth's voices: only broadcasters (and those let up) are heard.
fn hear_hearth(room: &Room, broadcasters: &std::collections::HashSet<String>, deaf: bool, people: &People) {
    hear(room, deaf, people, Some(broadcasters));
}

fn post(state: CallState) {
    Cx::post_action(Update::CallState(state));
}

/// `INFERNO_LOG_WEBRTC=1`: LiveKit's and WebRTC's own log on stderr (why a
/// connection failed; `=debug` also shows which video encoder was picked).
pub fn init_webrtc_log() {
    struct Stderr;
    impl log::Log for Stderr {
        fn enabled(&self, m: &log::Metadata) -> bool {
            m.level() <= log::max_level()
        }
        fn log(&self, r: &log::Record) {
            if self.enabled(r.metadata()) {
                eprintln!("[{} {}] {}", r.level(), r.target(), r.args());
            }
        }
        fn flush(&self) {}
    }
    static LOGGER: Stderr = Stderr;
    // `=debug` for WebRTC's detail (which encoder it picked, and why).
    let Some(level) = std::env::var_os("INFERNO_LOG_WEBRTC") else { return };
    if log::set_logger(&LOGGER).is_ok() {
        log::set_max_level(if level == "debug" { log::LevelFilter::Debug } else { log::LevelFilter::Info });
    }
}

/// What a video track shows.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum VideoKind {
    Camera,
    Screen,
}

/// Video on the GPU (Settings → Voice & Video): incoming frames stay YUV
/// and a shader turns them into colour; what we send is H.264, which the
/// GPU encodes (VA-API) where it can. Off: both on the CPU.
pub static GPU_VIDEO: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

/// A frame's pixels: BGRA (Makepad's texture layout, `0xAARRGGBB` per
/// u32), or the three I420 planes for the GPU to convert.
#[derive(Debug, Clone)]
pub enum Pixels {
    Bgra(Vec<u32>),
    I420 { y: Vec<u8>, u: Vec<u8>, v: Vec<u8>, stride_y: usize, stride_uv: usize },
}

/// The latest frame of a video we receive, its size, and a count that
/// changes with each new frame.
#[derive(Debug, Clone)]
pub struct Frame {
    pub width: usize,
    pub height: usize,
    /// `None` once taken by the UI.
    pub pixels: Option<Pixels>,
    pub seq: u64,
    pub at: std::time::Instant,
}

/// Who in the room is sharing their screen (LiveKit identities). Rails:
/// a stream is only downloaded once you press Watch.
pub static STREAMERS: Mutex<Option<std::collections::HashSet<String>>> = Mutex::new(None);

fn set_streaming(identity: &str, on: bool) {
    let mut s = STREAMERS.lock().unwrap_or_else(|e| e.into_inner());
    let set = s.get_or_insert_with(Default::default);
    if on {
        set.insert(identity.to_owned());
    } else {
        set.remove(identity);
    }
}

fn is_stream(source: TrackSource) -> bool {
    matches!(source, TrackSource::Screenshare | TrackSource::ScreenshareAudio)
}

/// `INFERNO_DEBUG_VIDEO`: frames a second, logged every 5 s.
pub struct Rate {
    since: std::time::Instant,
    frames: u32,
}

impl Rate {
    pub fn new() -> Option<Self> {
        std::env::var_os("INFERNO_DEBUG_VIDEO").map(|_| Self { since: std::time::Instant::now(), frames: 0 })
    }

    pub fn tick(&mut self, what: &str) {
        self.frames += 1;
        let t = self.since.elapsed().as_secs_f32();
        if t >= 5.0 {
            eprintln!("{what}: {:.1} fps", self.frames as f32 / t);
            self.frames = 0;
            self.since = std::time::Instant::now();
        }
    }
}

/// I420 planes for the GPU, rows packed tight (decoders pad rows; the
/// texture upload can't skip padding reliably).
pub fn i420_pixels(w: usize, h: usize, (y, u, v): (&[u8], &[u8], &[u8]), (sy, su, sv): (usize, usize, usize)) -> Pixels {
    let (cw, ch) = (w.div_ceil(2), h.div_ceil(2));
    let pack = |plane: &[u8], stride: usize, pw: usize, ph: usize| -> Vec<u8> {
        if stride == pw {
            return plane[..(pw * ph).min(plane.len())].to_vec();
        }
        let mut out = Vec::with_capacity(pw * ph);
        for row in plane.chunks(stride).take(ph) {
            out.extend_from_slice(&row[..pw.min(row.len())]);
        }
        out
    };
    Pixels::I420 { y: pack(y, sy, w, h), u: pack(u, su, cw, ch), v: pack(v, sv, cw, ch), stride_y: w, stride_uv: cw }
}

/// Every video we receive, by (LiveKit identity, kind).
pub static FRAMES: Mutex<Option<HashMap<(String, VideoKind), Frame>>> = Mutex::new(None);

/// Draws one incoming video into `FRAMES` for as long as it plays.
async fn watch_video(identity: String, kind: VideoKind, track: livekit::webrtc::prelude::RtcVideoTrack) {
    use futures_util::StreamExt;
    use livekit::webrtc::native::yuv_helper;
    let mut stream = livekit::webrtc::video_stream::native::NativeVideoStream::new(track);
    let mut seq = 0u64;
    let mut rate = Rate::new();
    while let Some(frame) = stream.next().await {
        let buffer = frame.buffer.as_ref();
        let (w, h) = (buffer.width() as usize, buffer.height() as usize);
        if w == 0 || h == 0 {
            continue;
        }
        let gpu = GPU_VIDEO.load(std::sync::atomic::Ordering::Relaxed);
        let pixels = match (buffer.as_i420(), buffer.as_nv12()) {
            // The planes as they are (equal U and V strides, as libwebrtc
            // makes them): the GPU converts.
            (Some(i420), _) if gpu => {
                let (y, u, v) = i420.data();
                let (sy, su, sv) = i420.strides();
                i420_pixels(w, h, (y, u, v), (sy as usize, su as usize, sv as usize))
            }
            (i420, nv12) => {
                let mut out = vec![0u32; w * h];
                // SAFETY: a u32 slice viewed as its bytes, same length × 4.
                let bytes = unsafe { std::slice::from_raw_parts_mut(out.as_mut_ptr() as *mut u8, w * h * 4) };
                if let Some(i420) = i420 {
                    let (y, u, v) = i420.data();
                    let (sy, su, sv) = i420.strides();
                    yuv_helper::i420_to_argb(y, sy, u, su, v, sv, bytes, (w * 4) as u32, w as i32, h as i32);
                } else if let Some(nv12) = nv12 {
                    let (y, uv) = nv12.data();
                    let (sy, suv) = nv12.strides();
                    yuv_helper::nv12_to_argb(y, sy, uv, suv, bytes, (w * 4) as u32, w as i32, h as i32);
                } else {
                    continue;
                }
                Pixels::Bgra(out)
            }
        };
        seq += 1;
        if let Some(r) = rate.as_mut() {
            r.tick(&format!("received {identity} {kind:?} {w}x{h}"));
        }
        FRAMES
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_or_insert_with(HashMap::new)
            .insert((identity.clone(), kind), Frame { width: w, height: h, pixels: Some(pixels), seq, at: std::time::Instant::now() });
    }
    if let Some(all) = FRAMES.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        all.remove(&(identity, kind));
    }
}

/// A test run's camera (`INFERNO_FAKE_VIDEO`): a moving pattern, so others'
/// cards can be seen showing video without a real camera.
async fn fake_camera(source: livekit::webrtc::video_source::native::NativeVideoSource) {
    use livekit::webrtc::video_frame::{I420Buffer, VideoFrame, VideoRotation};
    const W: u32 = 640;
    const H: u32 = 360;
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(1000 / 15));
    let mut n: u32 = 0;
    loop {
        tick.tick().await;
        let mut buffer = I420Buffer::new(W, H);
        let (sy, su, _) = buffer.strides();
        let (y, u, v) = buffer.data_mut();
        // Diagonal bands sliding along, over a slowly turning tint.
        for row in 0..H {
            for col in 0..W {
                y[(row * sy + col) as usize] = (((col + row + n * 4) / 16 % 2) * 120 + 60) as u8;
            }
        }
        for row in 0..H / 2 {
            for col in 0..W / 2 {
                u[(row * su + col) as usize] = (128 + (n % 100) as i32 - 50) as u8;
                v[(row * su + col) as usize] = 160;
            }
        }
        n += 1;
        let frame = VideoFrame { rotation: VideoRotation::VideoRotation0, timestamp_us: 0, frame_metadata: None, buffer };
        source.capture_frame(&frame);
    }
}

/// A test run's "screen": a checkerboard with a bar sweeping across, 16:9.
async fn fake_screen(source: livekit::webrtc::video_source::native::NativeVideoSource) {
    use livekit::webrtc::video_frame::{I420Buffer, VideoFrame, VideoRotation};
    const W: u32 = 1280;
    const H: u32 = 720;
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(1000 / 15));
    let mut n: u32 = 0;
    loop {
        tick.tick().await;
        let mut buffer = I420Buffer::new(W, H);
        let (sy, su, _) = buffer.strides();
        let (y, u, v) = buffer.data_mut();
        let bar = (n * 12) % W;
        for row in 0..H {
            for col in 0..W {
                let checker = ((col / 80) + (row / 80)) % 2 == 0;
                let on_bar = col >= bar && col < bar + 40;
                y[(row * sy + col) as usize] = if on_bar { 235 } else if checker { 90 } else { 40 };
            }
        }
        for row in 0..H / 2 {
            for col in 0..W / 2 {
                u[(row * su + col) as usize] = 150;
                v[(row * su + col) as usize] = 110;
            }
        }
        n += 1;
        let frame = VideoFrame { rotation: VideoRotation::VideoRotation0, timestamp_us: 0, frame_metadata: None, buffer };
        source.capture_frame(&frame);
    }
}

fn clear_levels() {
    *LEVELS.lock().unwrap_or_else(|e| e.into_inner()) = None;
    *FRAMES.lock().unwrap_or_else(|e| e.into_inner()) = None;
    *STREAMERS.lock().unwrap_or_else(|e| e.into_inner()) = None;
}

/// Drops someone's video (one kind, or all of theirs).
fn forget_video(identity: &str, kind: Option<VideoKind>) {
    if let Some(all) = FRAMES.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
        all.retain(|(id, k), _| !(id == identity && kind.is_none_or(|want| want == *k)));
    }
}

/// Measures one incoming voice for as long as it plays.
async fn meter(identity: String, track: livekit::webrtc::prelude::RtcAudioTrack) {
    use futures_util::StreamExt;
    let mut stream = livekit::webrtc::audio_stream::native::NativeAudioStream::new(track.clone(), 48_000, 1);
    let mut smoothed = 0.0f32;
    while let Some(frame) = stream.next().await {
        // A voice we don't hear (deafened, or a hearth speaker not
        // broadcasting) reads as silent: the glow follows what we hear.
        if !track.enabled() {
            smoothed = 0.0;
            continue;
        }
        let n = frame.data.len().max(1) as f32;
        let rms = (frame.data.iter().map(|s| (*s as f32 / 32768.0).powi(2)).sum::<f32>() / n).sqrt();
        smoothed = smoothed * 0.35 + rms * 0.65;
        LEVELS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .get_or_insert_with(HashMap::new)
            .insert(identity.clone(), (smoothed, std::time::Instant::now()));
    }
}

/// Every remote audio track in `room`, on or off.
/// Each person's volume (1 = as sent; Rails' 0..200%) and whether we've
/// muted them for ourselves, by LiveKit identity.
pub type People = HashMap<String, (f32, bool)>;

/// One remote voice as we want to hear it: on unless deafened or muted for
/// us (and, `gate` given, only if it passes), at its volume.
fn tune(t: &RemoteAudioTrack, identity: &str, deaf: bool, people: &People, gate: Option<&std::collections::HashSet<String>>) {
    let (volume, muted) = people.get(identity).copied().unwrap_or((1.0, false));
    let on = !deaf && !muted && gate.is_none_or(|g| g.contains(identity));
    if on {
        t.enable();
    } else {
        t.disable();
    }
    t.rtc_track().set_volume(volume as f64);
}

/// Every remote voice in `room`, retuned.
fn hear(room: &Room, deaf: bool, people: &People, gate: Option<&std::collections::HashSet<String>>) {
    for p in room.remote_participants().values() {
        let who = p.identity().to_string();
        for publication in p.track_publications().values() {
            if let Some(RemoteTrack::Audio(t)) = publication.track() {
                tune(&t, &who, deaf, people, gate);
            }
        }
    }
}

/// A test run's "voice" (`INFERNO_FAKE_MIC`): bursts of a quiet tone, so
/// the other side's speaking glow can be seen without a microphone.
async fn fake_voice(source: NativeAudioSource) {
    const RATE: u32 = 48_000;
    const FRAME: usize = (RATE / 100) as usize;
    let mut n: u64 = 0;
    let mut tick = tokio::time::interval(std::time::Duration::from_millis(10));
    loop {
        tick.tick().await;
        // The same made-up voice as the local meter's, as a tone whose
        // RMS is that level.
        let level = crate::voice_audio::fake_level().unwrap_or(0.0);
        let amp = level * std::f32::consts::SQRT_2 * 32767.0;
        let data: Vec<i16> = (0..FRAME).map(|i| ((((n + i as u64) as f32 / RATE as f32) * 2.0 * std::f32::consts::PI * 220.0).sin() * amp) as i16).collect();
        n += FRAME as u64;
        let frame = AudioFrame { data: data.into(), sample_rate: RATE, num_channels: 1, samples_per_channel: FRAME as u32 };
        if source.capture_frame(&frame).await.is_err() {
            break;
        }
    }
}

impl Calls {
    pub fn in_call(&self) -> bool {
        self.live.is_some()
    }

    /// Connects to `url` with `token` and publishes the microphone.
    pub async fn join(&mut self, url: &str, token: &str, mute: bool, deaf: bool, processing: Processing) -> Result<(), String> {
        // Switching rooms: the old call ends quietly (it isn't a drop).
        self.close().await;
        post(CallState::Connecting);
        let fake = std::env::var_os("INFERNO_FAKE_MIC").is_some();
        let audio = if fake { None } else { Some(PlatformAudio::new().map_err(|e| format!("No audio devices: {e}"))?) };
        if let Some(audio) = &audio {
            if let Some(d) = processing.input.as_ref().and_then(|n| audio.recording_devices().find(|d| &d.name == n)) {
                if let Err(e) = audio.set_recording_device(&d.id) {
                    makepad_widgets::log!("microphone {}: {e}", d.name);
                }
            }
            if let Some(d) = processing.output.as_ref().and_then(|n| audio.playout_devices().find(|d| &d.name == n)) {
                if let Err(e) = audio.set_playout_device(&d.id) {
                    makepad_widgets::log!("speaker {}: {e}", d.name);
                }
            }
            if let Err(e) = audio.configure_audio_processing(AudioProcessingOptions {
                echo_cancellation: processing.echo_cancellation,
                noise_suppression: processing.noise_suppression,
                auto_gain_control: processing.auto_gain_control,
                prefer_hardware_processing: false,
            }) {
                makepad_widgets::log!("audio processing: {e}");
            }
        }
        let mut options = RoomOptions::default();
        options.auto_subscribe = true;
        options.adaptive_stream = true;
        options.dynacast = true;
        let (room, events) = match Room::connect(url, token, options).await {
            Ok(r) => r,
            Err(e) => {
                post(CallState::Idle);
                return Err(format!("Couldn't connect to voice: {e}"));
            }
        };
        let room = Arc::new(room);
        let (source, tone) = match &audio {
            Some(a) => (a.rtc_source(), None),
            None => {
                let native = NativeAudioSource::new(AudioSourceOptions::default(), 48_000, 1, 100);
                (RtcAudioSource::Native(native.clone()), Some(tokio::spawn(fake_voice(native))))
            }
        };
        let mic = LocalAudioTrack::create_audio_track("microphone", source);
        let publish = TrackPublishOptions { source: TrackSource::Microphone, dtx: true, red: true, ..Default::default() };
        if let Err(e) = room.local_participant().publish_track(LocalTrack::Audio(mic.clone()), publish).await {
            // Rails: joined muted when the microphone is unavailable.
            makepad_widgets::log!("publishing the microphone: {e}");
        }
        if mute || deaf {
            mic.mute();
        }
        // A test run's camera (no real one is opened).
        let fake_cam = if std::env::var_os("INFERNO_FAKE_VIDEO").is_some() {
            use livekit::webrtc::video_source::{native::NativeVideoSource, RtcVideoSource, VideoResolution};
            let source = NativeVideoSource::new(VideoResolution { width: 640, height: 360 }, false);
            let track = LocalVideoTrack::create_video_track("camera", RtcVideoSource::Native(source.clone()));
            let codec = if GPU_VIDEO.load(std::sync::atomic::Ordering::Relaxed) { VideoCodec::H264 } else { VideoCodec::VP8 };
            let options = TrackPublishOptions { source: TrackSource::Camera, video_codec: codec, ..Default::default() };
            match room.local_participant().publish_track(LocalTrack::Video(track), options).await {
                Ok(_) => Some(tokio::spawn(fake_camera(source))),
                Err(e) => {
                    makepad_widgets::log!("test camera: {e}");
                    None
                }
            }
        } else {
            None
        };
        let deaf_flag = Arc::new(std::sync::atomic::AtomicBool::new(deaf));
        let (r, d, ppl, watching) = (room.clone(), deaf_flag.clone(), self.people.clone(), self.watching.clone());
        // Streams already running when we join.
        for p in room.remote_participants().values() {
            let who = p.identity().to_string();
            for publication in p.track_publications().values() {
                if is_stream(publication.source()) {
                    set_streaming(&who, true);
                    publication.set_subscribed(watching.lock().unwrap_or_else(|e| e.into_inner()).contains(&who));
                }
            }
        }
        let task = tokio::spawn(async move {
            let _room = r;
            let mut events = events;
            let mut meters: HashMap<String, tokio::task::JoinHandle<()>> = HashMap::new();
            let mut videos: HashMap<(String, VideoKind), tokio::task::JoinHandle<()>> = HashMap::new();
            while let Some(event) = events.recv().await {
                match event {
                    RoomEvent::TrackPublished { publication, participant } if is_stream(publication.source()) => {
                        let who = participant.identity().to_string();
                        set_streaming(&who, true);
                        let watched = watching.lock().unwrap_or_else(|e| e.into_inner()).contains(&who);
                        publication.set_subscribed(watched);
                    }
                    RoomEvent::TrackUnpublished { publication, participant } if publication.source() == TrackSource::Screenshare => {
                        let who = participant.identity().to_string();
                        set_streaming(&who, false);
                        if let Some(v) = videos.remove(&(who.clone(), VideoKind::Screen)) {
                            v.abort();
                        }
                        forget_video(&who, Some(VideoKind::Screen));
                    }
                    // A stream we haven't asked to watch (auto-subscribed on
                    // joining): dropped until we do.
                    RoomEvent::TrackSubscribed { publication, participant, .. }
                        if is_stream(publication.source()) && !watching.lock().unwrap_or_else(|e| e.into_inner()).contains(&participant.identity().to_string()) =>
                    {
                        set_streaming(&participant.identity().to_string(), true);
                        publication.set_subscribed(false);
                    }
                    RoomEvent::TrackSubscribed { track: RemoteTrack::Audio(t), publication, participant } if publication.source() == TrackSource::ScreenshareAudio => {
                        // A watched stream's sound, at its sharer's volume.
                        let who = participant.identity().to_string();
                        tune(&t, &who, d.load(std::sync::atomic::Ordering::Relaxed), &ppl.lock().unwrap_or_else(|e| e.into_inner()), None);
                    }
                    RoomEvent::TrackSubscribed { track: RemoteTrack::Video(t), publication, participant } => {
                        let kind = if publication.source() == TrackSource::Screenshare { VideoKind::Screen } else { VideoKind::Camera };
                        let who = participant.identity().to_string();
                        if kind == VideoKind::Screen {
                            set_streaming(&who, true);
                        }
                        if let Some(old) = videos.insert((who.clone(), kind), tokio::spawn(watch_video(who, kind, t.rtc_track()))) {
                            old.abort();
                        }
                    }
                    RoomEvent::TrackSubscribed { track: RemoteTrack::Audio(t), participant, .. } => {
                        let who = participant.identity().to_string();
                        tune(&t, &who, d.load(std::sync::atomic::Ordering::Relaxed), &ppl.lock().unwrap_or_else(|e| e.into_inner()), None);
                        if let Some(old) = meters.insert(who.clone(), tokio::spawn(meter(who, t.rtc_track()))) {
                            old.abort();
                        }
                    }
                    RoomEvent::TrackUnsubscribed { track: RemoteTrack::Video(_), publication, participant } => {
                        let kind = if publication.source() == TrackSource::Screenshare { VideoKind::Screen } else { VideoKind::Camera };
                        if let Some(v) = videos.remove(&(participant.identity().to_string(), kind)) {
                            v.abort();
                        }
                        forget_video(&participant.identity().to_string(), Some(kind));
                    }
                    RoomEvent::TrackUnsubscribed { participant, .. } => {
                        if let Some(m) = meters.remove(&participant.identity().to_string()) {
                            m.abort();
                        }
                    }
                    RoomEvent::ParticipantDisconnected(participant) => {
                        let who = participant.identity().to_string();
                        if let Some(m) = meters.remove(&who) {
                            m.abort();
                        }
                        videos.retain(|(id, _), v| {
                            if *id == who {
                                v.abort();
                            }
                            *id != who
                        });
                        forget_video(&who, None);
                        set_streaming(&who, false);
                    }
                    RoomEvent::Reconnecting => post(CallState::Reconnecting),
                    RoomEvent::Reconnected => post(CallState::Connected),
                    RoomEvent::Disconnected { reason } => {
                        makepad_widgets::log!("voice disconnected: {reason:?}");
                        post(CallState::Idle);
                        break;
                    }
                    _ => {}
                }
            }
            for m in meters.into_values() {
                m.abort();
            }
            for v in videos.into_values() {
                v.abort();
            }
            clear_levels();
        });
        hear(&room, deaf, &self.people.lock().unwrap_or_else(|e| e.into_inner()), None);
        // A test run's screen share (`INFERNO_FAKE_SCREEN`).
        let fake_screen = if std::env::var_os("INFERNO_FAKE_SCREEN").is_some() {
            use livekit::webrtc::video_source::{native::NativeVideoSource, RtcVideoSource, VideoResolution};
            let source = NativeVideoSource::new(VideoResolution { width: 1280, height: 720 }, true);
            let track = LocalVideoTrack::create_video_track("screen", RtcVideoSource::Native(source.clone()));
            let codec = if GPU_VIDEO.load(std::sync::atomic::Ordering::Relaxed) { VideoCodec::H264 } else { VideoCodec::VP8 };
            let options = TrackPublishOptions { source: TrackSource::Screenshare, video_codec: codec, ..Default::default() };
            match room.local_participant().publish_track(LocalTrack::Video(track), options).await {
                Ok(_) => Some(tokio::spawn(fake_screen(source))),
                Err(e) => {
                    makepad_widgets::log!("test screen: {e}");
                    None
                }
            }
        } else {
            None
        };
        if let Some(screen) = fake_screen {
            let r = room.clone();
            tokio::spawn(async move {
                while r.connection_state() != ConnectionState::Disconnected {
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                }
                screen.abort();
            });
        }
        if let Some(cam) = fake_cam {
            let r = room.clone();
            tokio::spawn(async move {
                while r.connection_state() != ConnectionState::Disconnected {
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                }
                cam.abort();
            });
        }
        if let Some(tone) = tone {
            // Ends with the call (the room's task outlives it otherwise).
            let r = room.clone();
            tokio::spawn(async move {
                while r.connection_state() != ConnectionState::Disconnected {
                    tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                }
                tone.abort();
            });
        }
        self.live = Some(Live { room, mic, _audio: audio, events: task, deaf: deaf_flag, relays: HashMap::new(), share: None });
        post(CallState::Connected);
        Ok(())
    }

    /// Also hears `hearth`'s room through a listen-only token (Rails: a
    /// hearth's audio radiates down to its embers). Its voices are metered
    /// like the room's own.
    pub async fn listen(&mut self, channel_id: &str, url: &str, token: &str) -> Result<(), String> {
        let Some(live) = self.live.as_mut() else { return Ok(()) };
        if live.relays.contains_key(channel_id) {
            return Ok(());
        }
        let mut options = RoomOptions::default();
        options.auto_subscribe = true;
        options.adaptive_stream = true;
        let (room, mut events) = Room::connect(url, token, options).await.map_err(|e| format!("Couldn't hear the hearth: {e}"))?;
        let room = Arc::new(room);
        let deaf = live.deaf.clone();
        let broadcasters = self.broadcasters.clone();
        let ppl = self.people.clone();
        hear_hearth(&room, &broadcasters.lock().unwrap_or_else(|e| e.into_inner()), deaf.load(std::sync::atomic::Ordering::Relaxed), &ppl.lock().unwrap_or_else(|e| e.into_inner()));
        let task = tokio::spawn(async move {
            let mut meters: HashMap<String, tokio::task::JoinHandle<()>> = HashMap::new();
            while let Some(event) = events.recv().await {
                match event {
                    RoomEvent::TrackSubscribed { track: RemoteTrack::Audio(t), participant, .. } => {
                        let who = participant.identity().to_string();
                        let gate = broadcasters.lock().unwrap_or_else(|e| e.into_inner()).clone();
                        tune(&t, &who, deaf.load(std::sync::atomic::Ordering::Relaxed), &ppl.lock().unwrap_or_else(|e| e.into_inner()), Some(&gate));
                        if let Some(old) = meters.insert(who.clone(), tokio::spawn(meter(who, t.rtc_track()))) {
                            old.abort();
                        }
                    }
                    RoomEvent::TrackUnsubscribed { participant, .. } | RoomEvent::ParticipantDisconnected(participant) => {
                        if let Some(m) = meters.remove(&participant.identity().to_string()) {
                            m.abort();
                        }
                    }
                    RoomEvent::Disconnected { .. } => break,
                    _ => {}
                }
            }
            for m in meters.into_values() {
                m.abort();
            }
        });
        live.relays.insert(channel_id.to_owned(), (room, task));
        Ok(())
    }

    /// The rooms heard listen-only, by channel.
    pub fn listening(&self) -> Vec<String> {
        self.live.as_ref().map(|l| l.relays.keys().cloned().collect()).unwrap_or_default()
    }

    pub async fn stop_listening(&mut self, channel_id: &str) {
        if let Some((room, task)) = self.live.as_mut().and_then(|l| l.relays.remove(channel_id)) {
            task.abort();
            let _ = room.close().await;
        }
    }

    /// Who in the hearths above is broadcasting now.
    pub fn set_broadcasters(&mut self, on: std::collections::HashSet<String>) {
        *self.broadcasters.lock().unwrap_or_else(|e| e.into_inner()) = on;
        self.retune();
    }

    pub async fn leave(&mut self) {
        if self.close().await {
            post(CallState::Idle);
        }
    }

    /// Shares a screen (`window` false) or window: Rails' Go Live.
    pub async fn start_share(&mut self, window: bool, id: u64, settings: crate::share::ShareSettings) -> Result<(), String> {
        use livekit::options::VideoEncoding;
        use livekit::webrtc::video_source::{native::NativeVideoSource, RtcVideoSource, VideoResolution};
        self.stop_share().await;
        let Some(live) = self.live.as_mut() else { return Err("You're not in voice.".into()) };
        let me = live.room.local_participant().identity().to_string();
        let source = NativeVideoSource::new(VideoResolution { width: settings.height * 16 / 9, height: settings.height }, true);
        let capture = crate::share::start(window, id, settings.clone(), source.clone(), me.clone(), || Cx::post_action(Update::ShareEnded))?;
        let track = LocalVideoTrack::create_video_track("screen", RtcVideoSource::Native(source));
        if std::env::var_os("INFERNO_DEBUG_VIDEO").is_some() {
            // What the encoder really does, every 5 s.
            let t = track.clone();
            tokio::spawn(async move {
                loop {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    let Ok(stats) = t.get_stats().await else { break };
                    for s in stats {
                        if let livekit::webrtc::stats::RtcStats::OutboundRtp(o) = s {
                            eprintln!(
                                "encoder {} {}x{} {:.1} fps, limited by {:?}",
                                o.outbound.encoder_implementation, o.outbound.frame_width, o.outbound.frame_height, o.outbound.frames_per_second, o.outbound.quality_limitation_reason
                            );
                        }
                    }
                }
            });
        }
        let codec = if GPU_VIDEO.load(std::sync::atomic::Ordering::Relaxed) { VideoCodec::H264 } else { VideoCodec::VP8 };
        let options = TrackPublishOptions {
            source: TrackSource::Screenshare,
            video_codec: codec,
            video_encoding: Some(VideoEncoding { max_bitrate: settings.bitrate(), max_framerate: settings.frame_rate() as f64 }),
            // Smoothness keeps the frame rate when bandwidth runs short;
            // clarity keeps the picture sharp (Rails' content hint).
            degradation_preference: Some(if settings.clarity {
                livekit::options::DegradationPreference::MaintainResolution
            } else {
                livekit::options::DegradationPreference::MaintainFramerate
            }),
            // One layer at full rate: LiveKit's extra screen share layer
            // runs at 3 fps, and viewers' small tiles would get that one.
            simulcast: false,
            ..Default::default()
        };
        let publication = live.room.local_participant().publish_track(LocalTrack::Video(track), options).await.map_err(|e| format!("Couldn't share: {e}"))?;
        live.share = Some((capture, publication.sid()));
        set_streaming(&me, true);
        Ok(())
    }

    /// Stops our screen share (true when there was one).
    pub async fn stop_share(&mut self) -> bool {
        let Some(live) = self.live.as_mut() else { return false };
        let Some((capture, sid)) = live.share.take() else { return false };
        drop(capture);
        let _ = live.room.local_participant().unpublish_track(&sid).await;
        let me = live.room.local_participant().identity().to_string();
        set_streaming(&me, false);
        forget_video(&me, Some(VideoKind::Screen));
        true
    }

    pub fn sharing(&self) -> bool {
        self.live.as_ref().is_some_and(|l| l.share.is_some())
    }

    /// Ends the call without telling the UI (true when there was one).
    async fn close(&mut self) -> bool {
        self.stop_share().await;
        let Some(live) = self.live.take() else { return false };
        live.events.abort();
        for (room, task) in live.relays.into_values() {
            task.abort();
            let _ = room.close().await;
        }
        let _ = live.room.close().await;
        clear_levels();
        true
    }

    /// Rails' mute and deafen (deafened is muted too).
    pub fn set_flags(&mut self, mute: bool, deaf: bool) {
        let Some(live) = &self.live else { return };
        if mute || deaf {
            live.mic.mute();
        } else {
            live.mic.unmute();
        }
        live.deaf.store(deaf, std::sync::atomic::Ordering::Relaxed);
        self.retune();
    }

    /// Everyone's audio again, after deafen, broadcasters or a person's
    /// volume or mute changed.
    fn retune(&self) {
        let Some(live) = &self.live else { return };
        let deaf = live.deaf.load(std::sync::atomic::Ordering::Relaxed);
        let people = self.people.lock().unwrap_or_else(|e| e.into_inner());
        hear(&live.room, deaf, &people, None);
        let b = self.broadcasters.lock().unwrap_or_else(|e| e.into_inner());
        for (room, _) in live.relays.values() {
            hear_hearth(room, &b, deaf, &people);
        }
    }

    /// Starts or stops watching someone's stream (Rails' Watch Stream /
    /// Stop watching): its video and sound are downloaded only meanwhile.
    pub fn watch(&mut self, identity: &str, on: bool) {
        {
            let mut w = self.watching.lock().unwrap_or_else(|e| e.into_inner());
            if on {
                w.insert(identity.to_owned());
            } else {
                w.remove(identity);
            }
        }
        if let Some(live) = &self.live {
            for p in live.room.remote_participants().values().filter(|p| p.identity().to_string() == identity) {
                for publication in p.track_publications().values() {
                    if is_stream(publication.source()) {
                        publication.set_subscribed(on);
                    }
                }
            }
        }
        if !on {
            forget_video(identity, Some(VideoKind::Screen));
        }
    }

    /// Per-person volume and mute-for-me, by LiveKit identity.
    pub fn set_people(&mut self, people: People) {
        *self.people.lock().unwrap_or_else(|e| e.into_inner()) = people;
        self.retune();
    }
}
