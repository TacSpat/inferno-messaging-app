//! Rails' image lightbox and video player, with Flutter's extra actions
//! (Copy Link, Open). Images: click to zoom 3× at the pointer, drag to pan,
//! the wheel to zoom (1–8×). Videos and sounds play in the same frame with
//! Rails' control bar: play, time, seek, volume, fullscreen.

use makepad_widgets::event::VideoSource;
use makepad_widgets::*;

use crate::{images, App, Toast};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Mode {
    #[default]
    Closed,
    Image,
    Video,
    Audio,
}

pub struct Viewer {
    pub mode: Mode,
    url: String,
    name: String,
    // The image: its size, the zoom, the pan from centre, a drag in progress.
    natural: Option<DVec2>,
    scale: f64,
    pan: DVec2,
    drag: Option<(DVec2, DVec2)>,
    dragged: bool,
    stage: Rect,
    // The player.
    dims: Option<(f64, f64)>,
    duration_ms: u128,
    playing: bool,
    ended: bool,
    pub(crate) volume: f64,
    pub(crate) muted: bool,
    seeking: bool,
    tick: Timer,
    hide: Timer,
    bar_shown: bool,
    // Downloads: the dialog's file, then the request in flight.
    save: Option<(LiveId, std::path::PathBuf, String)>,
    frame: NextFrame,
    /// A press began inside the open viewer (the click that opened it
    /// ends there too, and mustn't close it).
    pressed: bool,
    /// Reloading to play again from here (ms), once the old player is gone.
    restart_at: Option<u64>,
    last_pos: u128,
    moved: bool,
    /// A sound plays on Makepad's audio-only player, which reports no
    /// position: (its id, the position when last started, since when).
    sound: Option<LiveId>,
    sound_at: u128,
    sound_since: Option<std::time::Instant>,
}

impl Default for Viewer {
    fn default() -> Self {
        Viewer {
            mode: Mode::Closed,
            url: String::new(),
            name: String::new(),
            natural: None,
            scale: 1.0,
            pan: DVec2::default(),
            drag: None,
            dragged: false,
            stage: Rect::default(),
            dims: None,
            duration_ms: 0,
            playing: false,
            ended: false,
            volume: 1.0,
            muted: false,
            seeking: false,
            tick: Timer::empty(),
            hide: Timer::empty(),
            bar_shown: true,
            save: None,
            frame: NextFrame::default(),
            pressed: false,
            restart_at: None,
            last_pos: 0,
            moved: false,
            sound: None,
            sound_at: 0,
            sound_since: None,
        }
    }
}

/// Rails' `m:ss` (`h:mm:ss` past an hour).
pub fn clock(ms: u128) -> String {
    let s = (ms / 1000) as u64;
    let (h, m, s) = (s / 3600, (s / 60) % 60, s % 60);
    if h > 0 { format!("{h}:{m:02}:{s:02}") } else { format!("{m}:{s:02}") }
}

/// The largest size of `natural` inside `room`, never enlarged (Rails'
/// max-w-[90vw] max-h-[85vh] object-contain).
pub fn fit(natural: DVec2, room: DVec2) -> DVec2 {
    let k = (room.x / natural.x).min(room.y / natural.y).min(1.0).max(0.0);
    natural * k
}

/// Keeps a zoomed picture covering the frame (Rails' clampPan).
pub fn clamp_pan(pan: DVec2, shown: DVec2, scale: f64, room: DVec2) -> DVec2 {
    let max = dvec2(((shown.x * scale - room.x) / 2.0).max(0.0), ((shown.y * scale - room.y) / 2.0).max(0.0));
    dvec2(pan.x.clamp(-max.x, max.x), pan.y.clamp(-max.y, max.y))
}

/// A long name (a Blossom hash, mostly) cut in the middle.
fn short_name(name: &str) -> String {
    let chars: Vec<char> = name.chars().collect();
    if chars.len() <= 40 {
        return name.to_owned();
    }
    let head: String = chars[..24].iter().collect();
    let tail: String = chars[chars.len() - 10..].iter().collect();
    format!("{head}…{tail}")
}

/// A file name to save as: its own, with an extension from its type when
/// it has none (a Blossom hash).
fn save_name(name: &str, mime: Option<&str>) -> String {
    let name = if name.is_empty() { "download" } else { name };
    if name.contains('.') {
        return name.to_owned();
    }
    let ext = match mime.unwrap_or("") {
        "image/png" => "png",
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "image/webp" => "webp",
        "video/mp4" => "mp4",
        "video/webm" => "webm",
        "video/quicktime" => "mov",
        "audio/mpeg" => "mp3",
        "audio/ogg" => "ogg",
        _ => return name.to_owned(),
    };
    format!("{name}.{ext}")
}

const SAVE_DIALOG: LiveId = live_id!(save_media);

/// Where a mouse press went down, if this is one.
fn press_at(event: &Event) -> Option<DVec2> {
    match event {
        Event::MouseDown(e) => Some(e.abs),
        _ => None,
    }
}

/// Hits inside the open viewer. The modal locks the pointer to itself and
/// lifts the lock only while it handles its own content, so the viewer's
/// frames, tested from the app, lift it the same way.
fn hits(cx: &mut Cx, event: &Event, area: Area) -> Hit {
    let lock = cx.sweep_lock_area();
    if let Some(a) = lock {
        cx.sweep_unlock(a);
    }
    let hit = event.hits(cx, area);
    if let Some(a) = lock {
        cx.sweep_lock(a);
    }
    hit
}

impl App {
    pub(crate) fn open_image(&mut self, cx: &mut Cx, url: &str, name: &str) {
        let v = &mut self.viewer;
        *v = Viewer { volume: v.volume, muted: v.muted, ..Viewer::default() };
        v.mode = Mode::Image;
        v.url = url.to_owned();
        v.name = name.to_owned();
        self.ui.label(cx, ids!(lb_name)).set_text(cx, &short_name(name));
        let img = self.ui.image(cx, ids!(lb_img));
        images::show(cx, &img, Some(url));
        self.ui.modal(cx, ids!(lightbox)).open(cx);
        self.layout_image(cx);
    }

    /// `dims`: the video's shape from its imeta, until it loads.
    pub(crate) fn open_player(&mut self, cx: &mut Cx, url: &str, name: &str, audio: bool, dims: Option<(f64, f64)>) {
        let dims = if audio { Some((480.0, 270.0)) } else { dims };
        if let Some(old) = self.viewer.sound.take() {
            cx.cleanup_video_playback_resources(old);
        }
        let v = &mut self.viewer;
        *v = Viewer { volume: v.volume, muted: v.muted, ..Viewer::default() };
        v.mode = if audio { Mode::Audio } else { Mode::Video };
        v.url = url.to_owned();
        v.name = name.to_owned();
        v.dims = dims;
        v.playing = true;
        self.ui.label(cx, ids!(pl_name)).set_text(cx, &short_name(name));
        self.ui.label(cx, ids!(pl_audio_name)).set_text(cx, &short_name(name));
        self.ui.view(cx, ids!(pl_audio)).set_visible(cx, audio);
        // Hidden until this file is ready: until then it shows the last
        // one's frame. A sound keeps it hidden behind its card.
        let mut video_ref = self.ui.widget(cx, ids!(pl_video));
        script_apply_eval!(cx, video_ref, {draw_bg +: {opacity: 0.0}});
        let video = self.ui.video(cx, ids!(pl_video));
        if audio {
            self.start_sound(cx);
        } else if video.is_unprepared() {
            video.set_source(crate::media_cache::source(url));
            crate::media_cache::keep(cx, url);
            video.begin_playback(cx);
            video.set_volume(cx, if self.viewer.muted { 0.0 } else { self.viewer.volume });
        } else {
            // The last file's player is still going away: start once it has.
            if !video.is_cleaning_up() {
                video.stop_and_cleanup_resources(cx);
            }
            self.viewer.restart_at = Some(0);
        }
        self.viewer.tick = cx.start_interval(0.25);
        self.ui.modal(cx, ids!(player)).open(cx);
        self.show_bar(cx);
        self.layout_player(cx);
    }

    pub(crate) fn close_viewer(&mut self, cx: &mut Cx) {
        match self.viewer.mode {
            Mode::Image => self.ui.modal(cx, ids!(lightbox)).close(cx),
            Mode::Video | Mode::Audio => {
                // Only paused: a closed modal's widgets hear no events, so the
                // player would never learn its resources were released. The
                // next open tears it down while it can hear.
                self.ui.video(cx, ids!(pl_video)).pause_playback(cx);
                if let Some(id) = self.viewer.sound.take() {
                    cx.cleanup_video_playback_resources(id);
                }
                cx.stop_timer(self.viewer.tick);
                cx.stop_timer(self.viewer.hide);
                let window = self.ui.window(cx, ids!(main_window));
                if window.is_fullscreen(cx) {
                    window.disable_fullscreen(cx);
                }
                self.ui.modal(cx, ids!(player)).close(cx);
            }
            Mode::Closed => {}
        }
        self.viewer.mode = Mode::Closed;
    }

    /// Sizes and places the picture for the zoom and pan.
    fn layout_image(&mut self, cx: &mut Cx) {
        let stage = self.ui.view(cx, ids!(lb_stage)).area().rect(cx);
        self.viewer.stage = stage;
        if self.viewer.natural.is_none() && images::ensure(cx, &self.viewer.url) {
            if let Some(tex) = load_image_from_cache(cx, std::path::Path::new(&self.viewer.url)) {
                let frame = tex.animation(cx).as_ref().map(|a| (a.width, a.height));
                let size = frame.or_else(|| tex.get_format(cx).vec_width_height());
                self.viewer.natural = size.map(|(w, h)| dvec2(w.max(1) as f64, h.max(1) as f64));
            }
        }
        let (Some(natural), true) = (self.viewer.natural, stage.size.x > 0.0) else { return };
        let v = &mut self.viewer;
        let shown = fit(natural, stage.size);
        v.pan = clamp_pan(v.pan, shown, v.scale, stage.size);
        let size = shown * v.scale;
        let left = (stage.size.x - size.x) / 2.0 + v.pan.x;
        let top = (stage.size.y - size.y) / 2.0 + v.pan.y;
        let mut img = self.ui.widget(cx, ids!(lb_img));
        let (w, h) = (size.x, size.y);
        script_apply_eval!(cx, img, {width: #(w) height: #(h) margin: mod.prelude.widgets.Inset{left: #(left) top: #(top)}});
        self.redraw_soon(cx);
    }

    /// Layouts run as the frame is measured, often inside a draw, which
    /// drops a redraw asked for then: ask on the next frame.
    fn redraw_soon(&mut self, cx: &mut Cx) {
        self.viewer.frame = cx.new_next_frame();
    }

    /// The picture's rect on screen, as far as the frame shows it.
    fn image_rect(&self) -> Option<Rect> {
        let v = &self.viewer;
        let shown = fit(v.natural?, v.stage.size) * v.scale;
        let pos = v.stage.pos + (v.stage.size - shown) / 2.0 + v.pan;
        let lo = dvec2(pos.x.max(v.stage.pos.x), pos.y.max(v.stage.pos.y));
        let end = pos + shown;
        let stage_end = v.stage.pos + v.stage.size;
        let hi = dvec2(end.x.min(stage_end.x), end.y.min(stage_end.y));
        Some(Rect { pos: lo, size: dvec2((hi.x - lo.x).max(0.0), (hi.y - lo.y).max(0.0)) })
    }

    /// Fits the player's frame to the video's shape.
    fn layout_player(&mut self, cx: &mut Cx) {
        let stage = self.ui.view(cx, ids!(pl_stage)).area().rect(cx);
        self.viewer.stage = stage;
        if stage.size.x <= 0.0 {
            return;
        }
        let (w, h) = self.viewer.dims.unwrap_or((1280.0, 720.0));
        // Unlike pictures a video may grow, to fill the frame; a sound's
        // card stays its size.
        let k = (stage.size.x / w).min(stage.size.y / h);
        let k = if self.viewer.mode == Mode::Audio { k.min(1.0) } else { k };
        let size = dvec2(w * k, h * k);
        let mut b = self.ui.widget(cx, ids!(pl_box));
        let (w, h) = (size.x, size.y);
        script_apply_eval!(cx, b, {width: #(w) height: #(h)});
        self.redraw_soon(cx);
    }

    fn show_bar(&mut self, cx: &mut Cx) {
        if !self.viewer.bar_shown {
            self.viewer.bar_shown = true;
            self.ui.view(cx, ids!(pl_bar)).set_visible(cx, true);
        }
        cx.stop_timer(self.viewer.hide);
        self.viewer.hide = cx.start_timeout(2.0);
    }

    /// After a theme switch: the open player's bar as it was.
    pub(crate) fn repaint_viewer(&mut self, cx: &mut Cx) {
        if matches!(self.viewer.mode, Mode::Video | Mode::Audio) {
            self.refresh_controls(cx);
        }
    }

    fn refresh_controls(&mut self, cx: &mut Cx) {
        let at = self.position(cx);
        let v = &mut self.viewer;
        // The widget keeps the last file's numbers until this one is ready.
        let total = v.duration_ms;
        let pos = if total > 0 { at.min(total) } else { 0 };
        let frac = if total > 0 { (pos as f64 / total as f64).clamp(0.0, 1.0) } else { 0.0 };
        let text = format!("{} / {}", clock(pos), clock(total));
        let (playing, volume) = (v.playing && !v.ended, if v.muted { 0.0 } else { v.volume });
        self.ui.label(cx, ids!(pl_time)).set_text(cx, &text);
        let mut seek = self.ui.widget(cx, ids!(pl_seek));
        script_apply_eval!(cx, seek, {draw_bg +: {fill: #(frac)}});
        let mut vol = self.ui.widget(cx, ids!(pl_vol_bar));
        script_apply_eval!(cx, vol, {draw_bg +: {fill: #(volume)}});
        for (path, on) in [(ids!(pl_play.pause), playing), (ids!(pl_play.play), !playing)] {
            let mut ico = self.ui.widget(cx, path);
            let c = crate::theme::tok("gray_200", if on { 1.0 } else { 0.0 });
            script_apply_eval!(cx, ico, {draw_icon +: {color: #(c)}});
        }
        for (path, on) in [(ids!(pl_vol.on), volume > 0.0), (ids!(pl_vol.off), volume <= 0.0)] {
            let mut ico = self.ui.widget(cx, path);
            let c = crate::theme::tok("gray_200", if on { 1.0 } else { 0.0 });
            script_apply_eval!(cx, ico, {draw_icon +: {color: #(c)}});
        }
        // A sound's card has its own picture; the big button is for video.
        let big = !playing && self.viewer.mode == Mode::Video;
        self.ui.view(cx, ids!(pl_big)).set_visible(cx, big);
        self.ui.view(cx, ids!(pl_box)).redraw(cx);
    }

    fn toggle_play(&mut self, cx: &mut Cx) {
        let video = self.ui.video(cx, ids!(pl_video));
        if self.viewer.ended {
            self.restart(cx, 0);
        } else if self.viewer.playing {
            match self.viewer.sound {
                Some(id) => {
                    cx.pause_video_playback(id);
                    self.viewer.sound_at = self.position(cx);
                    self.viewer.sound_since = None;
                }
                None => video.pause_playback(cx),
            }
            self.viewer.playing = false;
        } else {
            match self.viewer.sound {
                Some(id) => {
                    cx.resume_video_playback(id);
                    self.viewer.sound_since = Some(std::time::Instant::now());
                }
                None => video.resume_playback(cx),
            }
            self.viewer.playing = true;
        }
        self.show_bar(cx);
        self.refresh_controls(cx);
    }

    /// Plays a finished video again from `at_ms`. GStreamer at its end
    /// takes no seek or resume, so the player is torn down and reloaded.
    fn restart(&mut self, cx: &mut Cx, at_ms: u64) {
        self.viewer.restart_at = Some(at_ms);
        if let Some(id) = self.viewer.sound.take() {
            cx.cleanup_video_playback_resources(id);
            self.start_sound(cx);
        } else {
            self.ui.video(cx, ids!(pl_video)).stop_and_cleanup_resources(cx);
        }
        self.viewer.moved = false;
        self.viewer.ended = false;
        self.viewer.playing = true;
    }

    fn set_volume(&mut self, cx: &mut Cx, volume: f64) {
        self.viewer.volume = volume.clamp(0.0, 1.0);
        self.viewer.muted = self.viewer.volume <= 0.0;
        self.apply_volume(cx);
        self.refresh_controls(cx);
    }

    fn apply_volume(&mut self, cx: &mut Cx) {
        let v = if self.viewer.muted { 0.0 } else { self.viewer.volume };
        match self.viewer.sound {
            Some(id) => cx.set_video_volume(id, v),
            None => self.ui.video(cx, ids!(pl_video)).set_volume(cx, v),
        }
    }

    /// Starts the sound on a new audio-only player.
    fn start_sound(&mut self, cx: &mut Cx) {
        let id = LiveId::unique();
        cx.prepare_audio_playback(id, VideoSource::Network(self.viewer.url.clone()), true, false);
        self.viewer.sound = Some(id);
        self.viewer.sound_at = 0;
        self.viewer.sound_since = None;
        self.apply_volume(cx);
    }

    /// Where playback is: the video's own count, or the sound's clock.
    fn position(&mut self, cx: &mut Cx) -> u128 {
        match self.viewer.sound {
            Some(_) => self.viewer.sound_at + self.viewer.sound_since.map_or(0, |t| t.elapsed().as_millis()),
            None => self.ui.video(cx, ids!(pl_video)).current_position_ms(),
        }
    }

    fn seek(&mut self, cx: &mut Cx, at: u64) {
        match self.viewer.sound {
            Some(id) => {
                cx.seek_video_playback(id, at);
                self.viewer.sound_at = at as u128;
                if self.viewer.sound_since.is_some() {
                    self.viewer.sound_since = Some(std::time::Instant::now());
                }
            }
            None => self.ui.video(cx, ids!(pl_video)).seek_to(cx, at),
        }
    }

    /// Save from a menu (a message's picture, video, sound or file): the
    /// viewer's download, for this file.
    pub(crate) fn save_media(&mut self, cx: &mut Cx, url: &str, name: &str) {
        if self.viewer.mode != Mode::Closed {
            return;
        }
        self.viewer.url = url.to_owned();
        self.viewer.name = if name.is_empty() { crate::message_format::file_name(None, url) } else { name.to_owned() };
        self.start_save(cx);
    }

    fn start_save(&mut self, cx: &mut Cx) {
        let mime = inferno_core::media::mime_for(&self.viewer.name);
        let mime = (mime != "application/octet-stream").then_some(mime).map(str::to_owned).or_else(|| {
            crate::media_probe::lookup(&self.viewer.url).map(|f| f.mime)
        });
        let name = save_name(&self.viewer.name, mime.as_deref());
        if let Ok(path) = std::env::var("INFERNO_TEST_SAVE") {
            self.download_to(cx, std::path::PathBuf::from(path));
            return;
        }
        cx.open_save_file_dialog(FileDialog::new().set_id(SAVE_DIALOG).set_title("Save".into()).set_filename(name));
    }

    fn download_to(&mut self, cx: &mut Cx, path: std::path::PathBuf) {
        let id = LiveId::unique();
        let mut req = HttpRequest::new(self.viewer.url.clone(), HttpMethod::GET);
        req.set_header("User-Agent".into(), "Inferno/0.1 (Nostr chat client)".into());
        cx.http_request(id, req);
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        self.viewer.save = Some((id, path, name));
    }

    pub(crate) fn viewer_handle_actions(&mut self, cx: &mut Cx, actions: &Actions) {
        for action in actions {
            if let Some(FileDialogAction::SaveFileSelected { id, path }) = action.downcast_ref::<FileDialogAction>() {
                if *id == SAVE_DIALOG {
                    self.download_to(cx, path.clone());
                }
            }
        }
        if self.viewer.mode == Mode::Closed {
            return;
        }
        let tap = |ui: &WidgetRef, cx: &mut Cx, path: &[LiveId]| ui.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled && e.was_tap());
        let image = self.viewer.mode == Mode::Image;
        let (copy, open, save, close) = if image {
            (ids!(lb_copy), ids!(lb_open), ids!(lb_save), ids!(lb_close))
        } else {
            (ids!(pl_copy), ids!(pl_open), ids!(pl_save), ids!(pl_close))
        };
        if tap(&self.ui, cx, copy) {
            cx.copy_to_clipboard(&self.viewer.url);
            self.toast(cx, "Link copied", Toast::Success);
        }
        if tap(&self.ui, cx, open) {
            cx.open_url(&self.viewer.url, OpenUrlInPlace::No);
        }
        if tap(&self.ui, cx, save) {
            self.start_save(cx);
        }
        let dismissed = self.ui.modal(cx, if image { ids!(lightbox) } else { ids!(player) }).dismissed(actions);
        if tap(&self.ui, cx, close) || dismissed {
            self.close_viewer(cx);
            return;
        }
        if !image {
            if tap(&self.ui, cx, ids!(pl_play)) {
                self.toggle_play(cx);
            }
            if tap(&self.ui, cx, ids!(pl_vol)) {
                self.viewer.muted = !self.viewer.muted || self.viewer.volume <= 0.0;
                if !self.viewer.muted && self.viewer.volume <= 0.0 {
                    self.viewer.volume = 1.0;
                }
                self.apply_volume(cx);
                self.refresh_controls(cx);
            }
            if tap(&self.ui, cx, ids!(pl_fs)) {
                let window = self.ui.window(cx, ids!(main_window));
                if window.is_fullscreen(cx) {
                    window.disable_fullscreen(cx);
                } else {
                    window.fullscreen(cx);
                }
            }
            let uid = self.ui.widget(cx, ids!(pl_video)).widget_uid();
            for action in actions {
                let Some(wa) = action.as_widget_action() else { continue };
                // The message's player says the same things.
                if wa.widget_uid != uid {
                    continue;
                }
                if let (VideoAction::PlayerReset, Some(_)) = (wa.cast::<VideoAction>(), self.viewer.restart_at) {
                    let video = self.ui.video(cx, ids!(pl_video));
                    video.set_source(crate::media_cache::source(&self.viewer.url));
                    video.begin_playback(cx);
                    video.set_volume(cx, if self.viewer.muted { 0.0 } else { self.viewer.volume });
                }
                // Makepad also says "completed" when it swaps a pipeline that
                // couldn't start, and when a finished one is torn down to
                // restart: only an end reached by playing counts.
                let video = self.ui.video(cx, ids!(pl_video));
                let total = self.viewer.duration_ms;
                let near_end = self.viewer.moved && total > 0 && video.current_position_ms() + 1000 >= total;
                if let (VideoAction::PlaybackCompleted, true) = (wa.cast::<VideoAction>(), near_end) {
                    self.viewer.ended = true;
                    self.viewer.playing = false;
                    self.show_bar(cx);
                    self.refresh_controls(cx);
                }
            }
        }
    }

    pub(crate) fn viewer_handle_event(&mut self, cx: &mut Cx, event: &Event) {
        if self.viewer.frame.is_event(event).is_some() {
            self.ui.redraw(cx);
        }
        // A download finishing: write it where the user said.
        if let (Event::NetworkResponses(responses), Some((id, _, _))) = (event, &self.viewer.save) {
            let id = *id;
            for r in responses.iter() {
                match r {
                    NetworkResponse::HttpResponse { request_id, response } if *request_id == id => {
                        let (_, path, name) = self.viewer.save.take().expect("pending");
                        let ok = (200..300).contains(&response.status_code)
                            && std::fs::write(&path, response.body.as_deref().unwrap_or(&[])).is_ok();
                        if ok {
                            self.toast(cx, &format!("Saved {name}"), Toast::Success);
                        } else {
                            self.toast(cx, &format!("Couldn't save {name}"), Toast::Error);
                        }
                    }
                    NetworkResponse::HttpError { request_id, .. } if *request_id == id => {
                        let (_, _, name) = self.viewer.save.take().expect("pending");
                        self.toast(cx, &format!("Couldn't download {name}"), Toast::Error);
                    }
                    _ => {}
                }
            }
        }
        match self.viewer.mode {
            Mode::Closed => {}
            Mode::Image => self.image_event(cx, event),
            Mode::Video | Mode::Audio => self.player_event(cx, event),
        }
    }

    fn image_event(&mut self, cx: &mut Cx, event: &Event) {
        // The frame moves with the window; the picture may arrive late.
        let stage = self.ui.view(cx, ids!(lb_stage)).area().rect(cx);
        if stage != self.viewer.stage || self.viewer.natural.is_none() && matches!(event, Event::NetworkResponses(_) | Event::Draw(_)) {
            self.layout_image(cx);
        }
        let root = self.ui.view(cx, ids!(lb_root)).area();
        let bar = self.ui.view(cx, ids!(lb_bar)).area().rect(cx);
        let close = self.ui.view(cx, ids!(lb_close)).area().rect(cx);
        // The viewer goes before the UI (the modal's scrim takes every press
        // after); its buttons keep theirs.
        if press_at(event).is_some_and(|p| bar.contains(p) || close.contains(p)) {
            return;
        }
        match hits(cx, event, root) {
            Hit::FingerDown(fe) => {
                self.viewer.pressed = true;
                self.viewer.dragged = false;
                self.viewer.drag = (self.viewer.scale > 1.0).then_some((fe.abs, self.viewer.pan));
                if self.viewer.drag.is_some() {
                    cx.set_cursor(MouseCursor::Move);
                }
            }
            Hit::FingerMove(fe) => {
                if let Some((start, pan)) = self.viewer.drag {
                    let d = fe.abs - start;
                    if d.x.abs() > 3.0 || d.y.abs() > 3.0 {
                        self.viewer.dragged = true;
                    }
                    self.viewer.pan = pan + d;
                    self.layout_image(cx);
                }
            }
            Hit::FingerUp(fe) => {
                self.viewer.drag = None;
                if !std::mem::take(&mut self.viewer.pressed) || self.viewer.dragged || bar.contains(fe.abs) {
                    return;
                }
                let on_image = self.image_rect().is_some_and(|r| r.contains(fe.abs));
                if !on_image {
                    // Rails: a click outside the picture closes.
                    self.close_viewer(cx);
                } else if self.viewer.scale > 1.0 {
                    self.viewer.scale = 1.0;
                    self.viewer.pan = DVec2::default();
                    self.layout_image(cx);
                } else if let Some(r) = self.image_rect() {
                    // Zoom 3× about the click.
                    let off = fe.abs - (r.pos + r.size / 2.0);
                    self.viewer.scale = 3.0;
                    self.viewer.pan = -off * 2.0;
                    self.layout_image(cx);
                }
            }
            Hit::FingerHoverIn(fe) | Hit::FingerHoverOver(fe) if self.image_rect().is_some_and(|r| r.contains(fe.abs)) => {
                cx.set_cursor(if self.viewer.scale > 1.0 { MouseCursor::Move } else { MouseCursor::Hand });
            }
            Hit::FingerScroll(se) => {
                let k = if se.scroll.y > 0.0 { 0.8 } else { 1.25 };
                self.viewer.scale = (self.viewer.scale * k).clamp(1.0, 8.0);
                if self.viewer.scale <= 1.0 {
                    self.viewer.pan = DVec2::default();
                }
                self.layout_image(cx);
            }
            _ => {}
        }
    }

    fn player_event(&mut self, cx: &mut Cx, event: &Event) {
        // The sound's player answers by its id.
        if let (Some(id), Event::VideoPlaybackPrepared(e)) = (self.viewer.sound, event) {
            if e.video_id == id {
                // Prepared, not started, whatever autoplay says.
                cx.begin_video_playback(id);
                self.viewer.duration_ms = e.duration;
                self.viewer.sound_since = Some(std::time::Instant::now());
                if let Some(at) = self.viewer.restart_at.take().filter(|at| *at > 0) {
                    cx.seek_video_playback(id, at);
                    self.viewer.sound_at = at as u128;
                }
                self.refresh_controls(cx);
            }
            return;
        }
        if let (Some(id), Event::VideoPlaybackCompleted(e)) = (self.viewer.sound, event) {
            if e.video_id == id && self.position(cx) > 0 {
                self.viewer.ended = true;
                self.viewer.playing = false;
                self.viewer.sound_since = None;
                self.viewer.sound_at = self.viewer.duration_ms;
                self.show_bar(cx);
                self.refresh_controls(cx);
            }
        }
        if let (None, Event::VideoPlaybackPrepared(e)) = (self.viewer.sound, event) {
            if self.viewer.mode == Mode::Video && e.video_width > 0 && e.video_height > 0 {
                self.viewer.dims = Some((e.video_width as f64, e.video_height as f64));
            }
            self.viewer.duration_ms = e.duration;
            if self.viewer.mode == Mode::Video {
                let mut video_ref = self.ui.widget(cx, ids!(pl_video));
                script_apply_eval!(cx, video_ref, {draw_bg +: {opacity: 1.0}});
            }
            if self.viewer.restart_at == Some(0) {
                self.viewer.restart_at = None;
            }
            self.layout_player(cx);
            self.refresh_controls(cx);
        }
        if self.viewer.tick.is_event(event).is_some() && self.viewer.sound.is_some() {
            // Its clock past the end is the end, if the player didn't say.
            let total = self.viewer.duration_ms;
            if self.viewer.playing && total > 0 && self.position(cx) >= total + 500 {
                self.viewer.ended = true;
                self.viewer.playing = false;
                self.viewer.sound_since = None;
                self.viewer.sound_at = total;
                self.show_bar(cx);
            }
            self.refresh_controls(cx);
        } else if self.viewer.tick.is_event(event).is_some() {
            // The end isn't always reported (after a restart, mostly): a
            // position that stops at the end is the end too.
            let video = self.ui.video(cx, ids!(pl_video));
            let (pos, total) = (video.current_position_ms(), self.viewer.duration_ms);
            // A restart part-way seeks once the reloaded player is running
            // (seeking it sooner stalls it).
            if let Some(at) = self.viewer.restart_at.filter(|_| pos > 0) {
                self.viewer.restart_at = None;
                video.seek_to(cx, at);
            }
            // Only once it has moved: a reloaded player first repeats where
            // the old one stopped.
            self.viewer.moved |= pos != self.viewer.last_pos && pos < self.viewer.last_pos.saturating_add(2000) && pos > self.viewer.last_pos;
            let stalled = self.viewer.moved && pos == self.viewer.last_pos && total > 0 && pos + 1000 >= total;
            if self.viewer.playing && stalled && self.viewer.restart_at.is_none() {
                self.viewer.ended = true;
                self.viewer.playing = false;
                self.show_bar(cx);
            }
            self.viewer.last_pos = pos;
            self.refresh_controls(cx);
        }
        if self.viewer.hide.is_event(event).is_some() && self.viewer.playing && !self.viewer.seeking {
            self.viewer.bar_shown = false;
            self.ui.view(cx, ids!(pl_bar)).set_visible(cx, false);
            self.ui.view(cx, ids!(pl_box)).redraw(cx);
        }
        let stage = self.ui.view(cx, ids!(pl_stage)).area().rect(cx);
        if stage != self.viewer.stage {
            self.layout_player(cx);
        }
        // Seeking and the volume: press or drag along the bar.
        for (path, seek) in [(ids!(pl_seek), true), (ids!(pl_vol_bar), false)] {
            let area = self.ui.view(cx, path).area();
            let r = area.rect(cx);
            let at = |abs: DVec2| ((abs.x - r.pos.x) / r.size.x.max(1.0)).clamp(0.0, 1.0);
            let frac = match hits(cx, event, area) {
                Hit::FingerDown(fe) => Some(at(fe.abs)),
                Hit::FingerMove(fe) => Some(at(fe.abs)),
                Hit::FingerUp(_) => {
                    self.viewer.seeking = false;
                    None
                }
                Hit::FingerHoverIn(_) | Hit::FingerHoverOver(_) => {
                    cx.set_cursor(MouseCursor::Hand);
                    None
                }
                _ => None,
            };
            if let Some(f) = frac {
                self.viewer.seeking = true;
                if seek {
                    let total = self.viewer.duration_ms;
                    if total > 0 {
                        let at = (f * total as f64) as u64;
                        if self.viewer.ended {
                            self.restart(cx, at);
                        } else {
                            self.seek(cx, at);
                        }
                    }
                    self.refresh_controls(cx);
                } else {
                    self.set_volume(cx, f);
                }
                self.show_bar(cx);
            }
        }
        // Moving over the video shows the bar; a click on it plays or pauses;
        // a click beside it closes.
        let root = self.ui.view(cx, ids!(pl_root)).area();
        let frame = self.ui.view(cx, ids!(pl_box)).area().rect(cx);
        let bar = self.ui.view(cx, ids!(pl_bar)).area().rect(cx);
        let under = self.ui.view(cx, ids!(pl_info)).area().rect(cx);
        let close = self.ui.view(cx, ids!(pl_close)).area().rect(cx);
        if press_at(event).is_some_and(|p| self.viewer.bar_shown && bar.contains(p) || under.contains(p) || close.contains(p)) {
            return;
        }
        match hits(cx, event, root) {
            Hit::FingerHoverOver(fe) | Hit::FingerHoverIn(fe) if frame.contains(fe.abs) => self.show_bar(cx),
            Hit::FingerDown(_) => self.viewer.pressed = true,
            Hit::FingerUp(fe) if std::mem::take(&mut self.viewer.pressed) && fe.was_tap() => {
                let on_controls = self.viewer.bar_shown && bar.contains(fe.abs) || under.contains(fe.abs);
                if on_controls {
                    // Their own buttons answer.
                } else if frame.contains(fe.abs) {
                    self.toggle_play(cx);
                } else {
                    self.close_viewer(cx);
                }
            }
            _ => {}
        }
        if let Event::KeyDown(k) = event {
            if k.key_code == KeyCode::Space {
                self.toggle_play(cx);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clocks_fits_and_pans() {
        assert_eq!(clock(65_000), "1:05");
        assert_eq!(clock(3_725_000), "1:02:05");
        assert_eq!(fit(dvec2(400.0, 200.0), dvec2(1000.0, 1000.0)), dvec2(400.0, 200.0), "never enlarged");
        assert_eq!(fit(dvec2(2000.0, 1000.0), dvec2(1000.0, 1000.0)), dvec2(1000.0, 500.0));
        // 3× of a 1000×500 picture in a 1000×800 frame pans ±1000 across, ±350 down.
        assert_eq!(clamp_pan(dvec2(5000.0, -5000.0), dvec2(1000.0, 500.0), 3.0, dvec2(1000.0, 800.0)), dvec2(1000.0, -350.0));
        assert_eq!(save_name("abc", Some("video/mp4")), "abc.mp4");
        assert_eq!(short_name(&"a".repeat(64)), format!("{}…{}", "a".repeat(24), "a".repeat(10)));
        assert_eq!(save_name("cat.png", Some("image/gif")), "cat.png");
    }
}
