//! Rails' inline video player (video_player_controller): a video plays where
//! it sits in the message. The big play button shows while it's stopped; a
//! bar of play, time, seek, volume and fullscreen slides in while the pointer
//! is over it and hides 2s into playback (kept while paused part-way).
//!
//! One player is shared. Message rows are reused as the list scrolls, so the
//! player isn't part of any row: the message body drawing the playing card
//! draws the player in its place, and it scrolls and clips with the list.
//! Fullscreen hands the video to the viewer's player, from where it was.

use std::cell::{Cell, RefCell};
use std::collections::HashMap;

use makepad_widgets::*;

use crate::media_view::clock;
use crate::App;

thread_local! {
    /// The playing card (`message id|url`) and the player drawn in its place.
    static ACTIVE: RefCell<Option<(String, WidgetRef)>> = const { RefCell::new(None) };
    /// The message whose row is being drawn.
    static ROW: RefCell<String> = const { RefCell::new(String::new()) };
    static SEEN: Cell<bool> = const { Cell::new(false) };
    static VISIBLE: Cell<bool> = const { Cell::new(false) };
    /// Videos' shapes once played, for the ones that came without one.
    static DIMS: RefCell<HashMap<String, (f64, f64)>> = RefCell::new(HashMap::new());
    /// The playing video fills the window (Rails' fullscreen).
    static FULL: Cell<bool> = const { Cell::new(false) };
    /// The first-frame players and what each is lent to.
    static POSTERS: RefCell<Vec<(WidgetRef, Poster)>> = const { RefCell::new(Vec::new()) };
}

/// A first-frame player's state.
#[derive(Default)]
pub struct Poster {
    /// The video it holds (or is loading).
    url: Option<String>,
    /// The video it loads once its last one is let go.
    next: Option<String>,
    /// When a card last drew it: one off screen for a moment can be lent again.
    drawn: Option<std::time::Instant>,
    /// Its frame is in.
    ready: bool,
}

/// The app hands over the first-frame players once (they live in the host).
pub fn set_posters(players: Vec<WidgetRef>) {
    // Their first frame is the news (see posters_handle_actions).
    for p in &players {
        p.as_video().should_dispatch_texture_updates(true);
    }
    POSTERS.with(|p| *p.borrow_mut() = players.into_iter().map(|w| (w, Poster::default())).collect());
}

pub fn posters_set() -> bool {
    POSTERS.with(|p| !p.borrow().is_empty())
}

fn load_poster(cx: &mut Cx, player: &WidgetRef, url: &str) {
    let video = player.as_video();
    video.set_source(crate::media_cache::source(url));
    video.prepare_playback(cx);
    // A linked video is saved the first time its card shows.
    crate::media_cache::keep(cx, url);
}

/// The first-frame player for `url` once its frame is in. One is lent if
/// none has it: the one a card hasn't drawn for longest, if none is on
/// screen (all busy on screen: the card stays black).
pub fn poster_for(cx: &mut Cx, url: &str) -> Option<WidgetRef> {
    if url.is_empty() {
        return None;
    }
    POSTERS.with(|p| {
        let mut posters = p.borrow_mut();
        let now = std::time::Instant::now();
        if let Some((player, poster)) = posters.iter_mut().find(|(_, s)| s.url.as_deref() == Some(url) || s.next.as_deref() == Some(url)) {
            poster.drawn = Some(now);
            return (poster.ready && poster.url.as_deref() == Some(url)).then(|| player.clone());
        }
        let free = |s: &Poster| s.drawn.is_none_or(|t| now.duration_since(t).as_secs_f64() > 1.0);
        let (player, poster) = posters.iter_mut().filter(|(_, s)| free(s)).min_by_key(|(_, s)| s.drawn)?;
        poster.drawn = Some(now);
        poster.ready = false;
        let mut hide = player.clone();
        script_apply_eval!(cx, hide, {draw_bg +: {opacity: 0.0}});
        let video = player.as_video();
        if video.is_unprepared() {
            poster.url = Some(url.to_owned());
            poster.next = None;
            load_poster(cx, player, url);
        } else {
            poster.next = Some(url.to_owned());
            if !video.is_cleaning_up() {
                video.stop_and_cleanup_resources(cx);
            }
        }
        None
    })
}

/// The first-frame players' news: a frame in (show it), a shape and length
/// learnt (true: the cards should be laid out again), an old video let go
/// (load the next).
pub fn posters_handle_actions(cx: &mut Cx, actions: &Actions) -> bool {
    let mut relayout = false;
    POSTERS.with(|p| {
        let mut posters = p.borrow_mut();
        for action in actions {
            let Some(wa) = action.as_widget_action() else { continue };
            let Some((player, poster)) = posters.iter_mut().find(|(w, _)| w.widget_uid() == wa.widget_uid) else { continue };
            match wa.cast::<VideoAction>() {
                VideoAction::PlayerReset => {
                    if let Some(url) = poster.next.take() {
                        poster.url = Some(url.clone());
                        load_poster(cx, player, &url);
                    }
                }
                VideoAction::PlaybackPrepared => {
                    // Before its frame: restyling a player resets the shader
                    // settings each frame brings, and a poster gets one frame.
                    let mut show = player.clone();
                    script_apply_eval!(cx, show, {draw_bg +: {opacity: 1.0}});
                    let video = player.as_video();
                    let Some(url) = poster.url.clone() else { continue };
                    let (w, h) = video.video_size();
                    if w > 0 && h > 0 {
                        let shape = (w as f64, h as f64);
                        relayout |= DIMS.with(|d| d.borrow_mut().insert(url.clone(), shape)) != Some(shape);
                    }
                }
                VideoAction::TextureUpdated if !poster.ready => {
                    poster.ready = true;
                    relayout = true;
                }
                _ => {}
            }
        }
    });
    relayout
}

/// After a theme switch: restyling a player loses its frame, and a
/// first-frame player gets one frame, so each reloads its video.
pub fn reload_posters(cx: &mut Cx) {
    POSTERS.with(|p| {
        for (player, poster) in p.borrow_mut().iter_mut() {
            let Some(url) = poster.url.take().or(poster.next.take()) else { continue };
            poster.ready = false;
            poster.next = Some(url);
            let video = player.as_video();
            if video.is_unprepared() {
                poster.url = poster.next.take();
                load_poster(cx, player, poster.url.as_deref().unwrap_or(""));
            } else if !video.is_cleaning_up() {
                video.stop_and_cleanup_resources(cx);
            }
        }
    });
}

/// Draws the first frame of its card's video, when one is lent.
#[derive(Script, ScriptHook, Widget)]
pub struct PosterSlot {
    #[deref]
    view: View,
    #[rust]
    pub url: String,
}

impl Widget for PosterSlot {
    fn handle_event(&mut self, _cx: &mut Cx, _event: &Event, _scope: &mut Scope) {}

    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        let player = poster_for(cx, &self.url);
        if let Some(player) = player {
            while player.draw_walk(cx, scope, walk).is_step() {}
        }
        DrawStep::done()
    }
}

/// Rails' fullscreen: the playing video on black, filling the window. The
/// same player keeps playing (no reload, so no pause going in or out).
#[derive(Script, ScriptHook, Widget)]
pub struct InlineFullHost {
    #[deref]
    view: View,
    /// The video's frame inside the player last laid out (size, offset).
    #[rust]
    fitted: Option<(DVec2, DVec2)>,
}

impl Widget for InlineFullHost {
    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        if FULL.get() {
            self.view.handle_event(cx, event, scope);
        }
    }

    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        if !FULL.get() {
            return DrawStep::done();
        }
        let Some((url, player)) = ACTIVE.with(|a| a.borrow().as_ref().map(|(k, p)| (k.split_once('|').map_or(k.clone(), |(_, u)| u.to_owned()), p.clone()))) else {
            return DrawStep::done();
        };
        while self.view.draw_walk(cx, scope, walk).is_step() {}
        let room = self.view.area().rect(cx);
        // Rails: the player fills the screen (its bar the whole width), the
        // video centred in it at its own shape. Makepad's Video stretches to
        // its box, so the box is the video's shape.
        let (w, h) = dims_of(&url).unwrap_or((1280.0, 720.0));
        let k = (room.size.x / w).min(room.size.y / h);
        let size = dvec2(w * k, h * k);
        let offset = (room.size - size) / 2.0;
        if self.fitted != Some((size, offset)) {
            self.fitted = Some((size, offset));
            if let Some(mut frame) = player.view(cx, ids!(ip_frame)).borrow_mut() {
                frame.walk.width = Size::Fixed(size.x);
                frame.walk.height = Size::Fixed(size.y);
                frame.walk.margin.left = offset.x;
                frame.walk.margin.top = offset.y;
            }
        }
        let walk = Walk { abs_pos: Some(room.pos), ..Walk::fixed(room.size.x, room.size.y) };
        while player.draw_walk(cx, scope, walk).is_step() {}
        DrawStep::done()
    }
}

/// The message list says whose row it's drawing ("" when done).
pub fn set_row(id: &str) {
    ROW.with(|r| {
        let mut r = r.borrow_mut();
        r.clear();
        r.push_str(id);
    });
}

/// The key of `url`'s card in the row being drawn; empty outside the list
/// (the pins panel), where videos open in the viewer.
pub fn key(url: &str) -> String {
    ROW.with(|r| {
        let r = r.borrow();
        if r.is_empty() { String::new() } else { format!("{r}|{url}") }
    })
}

/// The player, when `key` is the card playing.
pub fn player_for(key: &str) -> Option<WidgetRef> {
    if key.is_empty() || FULL.get() {
        return None;
    }
    ACTIVE.with(|a| a.borrow().as_ref().filter(|(k, _)| k == key).map(|(_, p)| p.clone()))
}

/// The list's draw: whether the playing message is among its rows on screen.
/// Off screen its last rect is stale, so it takes no clicks there.
pub fn begin_pass() {
    SEEN.set(false);
}

pub fn see_row(id: &str) {
    let playing = ACTIVE.with(|a| a.borrow().as_ref().is_some_and(|(k, _)| k.split('|').next() == Some(id)));
    if playing {
        SEEN.set(true);
    }
}

pub fn end_pass() {
    VISIBLE.set(SEEN.get());
}

/// The player is on screen: in its message, or filling the window.
fn on_screen() -> bool {
    VISIBLE.get() || FULL.get()
}

pub fn dims_of(url: &str) -> Option<(f64, f64)> {
    DIMS.with(|d| d.borrow().get(url).copied())
}

/// The card's size: Rails' max-w-lg max-h-96, never enlarged; 16:9 until
/// the shape is known.
pub fn card_size(dims: Option<(f64, f64)>) -> (f64, f64) {
    match dims.filter(|(w, h)| *w > 0.0 && *h > 0.0) {
        Some((w, h)) => {
            let k = (512.0 / w).min(384.0 / h).min(1.0);
            ((w * k).max(160.0), (h * k).max(90.0))
        }
        None => (400.0, 225.0),
    }
}

/// Keeps the player in the UI, where it hears its events; it draws nothing
/// here (the playing message draws it).
#[derive(Script, ScriptHook, Widget)]
pub struct InlineVideoHost {
    #[deref]
    view: View,
}

impl Widget for InlineVideoHost {
    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        // The first-frame players hear no pointer: Makepad's Video plays on
        // a tap, and the card they're drawn in takes its own clicks.
        let pointer = matches!(
            event,
            Event::MouseDown(_) | Event::MouseUp(_) | Event::MouseMove(_) | Event::MouseLeave(_) | Event::Scroll(_) | Event::TouchUpdate(_)
        );
        if pointer {
            self.view.widget(cx, ids!(ip_box)).handle_event(cx, event, scope);
        } else {
            self.view.handle_event(cx, event, scope);
        }
    }

    fn draw_walk(&mut self, _cx: &mut Cx2d, _scope: &mut Scope, _walk: Walk) -> DrawStep {
        DrawStep::done()
    }
}

/// Rails' .vp-controls slide (transform/opacity 0.25s ease).
const SLIDE_SECS: f64 = 0.25;
/// Rails' .vp-big-play fade (opacity 0.2s).
const BIG_FADE_SECS: f64 = 0.2;

/// CSS `ease`, near enough.
pub fn ease(t: f64) -> f64 {
    t * t * (3.0 - 2.0 * t)
}

#[derive(Default)]
pub struct Inline {
    key: String,
    url: String,
    playing: bool,
    ended: bool,
    duration_ms: u128,
    last_pos: u128,
    /// It has played on from where it started (see media_view).
    moved: bool,
    /// Reloading to play from here (ms) once the old player is gone.
    restart_at: Option<u64>,
    tick: Timer,
    hide: Timer,
    /// Where the bar is headed, and how far in it is (0 away, 1 in).
    bar_shown: bool,
    bar_t: f64,
    /// The big play button's fade (1 shown).
    big_t: f64,
    anim: NextFrame,
    anim_at: Option<std::time::Instant>,
    /// The pointer is over the player, and over which bar button.
    inside: bool,
    hover_btn: Option<BarButton>,
    /// Paused part-way: the bar stays (Rails' pinned).
    pinned: bool,
    seeking: bool,
    seek_hover: bool,
    /// Where a seek drag is (ms), shown until it's let go and the player
    /// gets there: it seeks once, on release (Rails seeks on a click; a
    /// paused player handed a stream of seeks stalls).
    seek_shown: Option<(u64, Option<std::time::Instant>)>,
    /// Where a press on the video went down.
    pressed: Option<DVec2>,
    /// A portrait video: its volume is the popup above the button.
    portrait: bool,
    vol_pop: bool,
    vol_pop_hide: Timer,
    vol_dragging: bool,
}

/// Rails' .vp-vertical: a portrait video's seek bar gets its own row, and
/// the volume slider makes way (Rails moves it to a popup).
pub fn portrait(dims: Option<(f64, f64)>) -> bool {
    dims.is_some_and(|(w, h)| h > w)
}

/// Lays a control bar out for the video's shape (the cards' and the player's).
pub fn shape_bar(cx: &mut Cx, bar: &WidgetRef, portrait: bool) {
    bar.view(cx, ids!(seek_top)).set_visible(cx, portrait);
    bar.view(cx, ids!(seek)).set_visible(cx, !portrait);
    bar.view(cx, ids!(vol_bar)).set_visible(cx, !portrait);
    bar.view(cx, ids!(push)).set_visible(cx, portrait);
    // Rails' .vp-vertical .vp-time: 11px (12px otherwise).
    let size = if portrait { 8.25 } else { 9.0 };
    let mut time = bar.widget(cx, ids!(time));
    script_apply_eval!(cx, time, {draw_text +: {text_style +: {font_size: #(size)}}});
}

/// A bar button under the pointer (Rails' .vp-btn:hover turns it white).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BarButton {
    Play,
    Volume,
    Fullscreen,
}

/// What a control bar shows.
pub struct BarLook {
    pub pos: u128,
    pub total: u128,
    pub playing: bool,
    pub volume: f64,
    /// The seek bar under the pointer or being dragged (6px tall).
    pub grow: bool,
    /// How far in it has faded (Rails fades it as it slides).
    pub alpha: f64,
    pub hover: Option<BarButton>,
}

/// Fills a control bar in: time, played part, volume, which icons show.
pub fn paint_bar(cx: &mut Cx, bar: &WidgetRef, look: &BarLook) {
    let pos = look.pos.min(look.total);
    let frac = if look.total > 0 { (pos as f64 / look.total as f64).clamp(0.0, 1.0) } else { 0.0 };
    let a = look.alpha as f32;
    let alpha = look.alpha;
    // The bar's own gradient first: applying to the bar re-applies its
    // children's styles.
    let mut bg = bar.clone();
    script_apply_eval!(cx, bg, {draw_bg +: {alpha: #(alpha)}});
    let mut time = bar.widget(cx, ids!(time));
    time.set_text(cx, &format!("{} / {}", clock(pos), clock(look.total)));
    let tc = crate::theme::tok("gray_400", a);
    script_apply_eval!(cx, time, {draw_text +: {color: #(tc)}});
    let g = if look.grow { 1.0 } else { 0.0 };
    for path in [ids!(seek), ids!(seek_top)] {
        let mut seek = bar.widget(cx, path);
        script_apply_eval!(cx, seek, {draw_bg +: {fill: #(frac) grow: #(g) alpha: #(alpha)}});
    }
    let volume = look.volume;
    let mut vol = bar.widget(cx, ids!(vol_bar));
    script_apply_eval!(cx, vol, {draw_bg +: {fill: #(volume) alpha: #(alpha)}});
    let lit = |b: BarButton| look.hover == Some(b);
    let icons = [
        (ids!(play_btn.pause), look.playing, lit(BarButton::Play)),
        (ids!(play_btn.play), !look.playing, lit(BarButton::Play)),
        (ids!(vol.on), look.volume > 0.0, lit(BarButton::Volume)),
        (ids!(vol.off), look.volume <= 0.0, lit(BarButton::Volume)),
        (ids!(fs.icon), true, lit(BarButton::Fullscreen)),
    ];
    for (path, on, hovered) in icons {
        let mut ico = bar.widget(cx, path);
        // The theme's gray-200, white under the pointer.
        let alpha = if on { a } else { 0.0 };
        let c = if hovered { vec4(1.0, 1.0, 1.0, alpha) } else { crate::theme::tok("gray_200", alpha) };
        script_apply_eval!(cx, ico, {draw_icon +: {color: #(c)}});
    }
}

/// Which bar button is at `abs`, if the bar is in.
pub fn button_at(cx: &mut Cx, bar: &WidgetRef, abs: DVec2) -> Option<BarButton> {
    let buttons: [(&[LiveId], BarButton); 3] =
        [(ids!(play_btn), BarButton::Play), (ids!(vol), BarButton::Volume), (ids!(fs), BarButton::Fullscreen)];
    buttons
        .into_iter()
        .find(|(path, _)| bar.view(cx, path).area().rect(cx).contains(abs))
        .map(|(_, b)| b)
}

impl App {
    /// A click on a video card: play it here, or play/pause the one playing.
    pub(crate) fn play_inline(&mut self, cx: &mut Cx, key: String, url: String) {
        if key == self.inline.key {
            self.inline_toggle(cx);
            return;
        }
        let video = self.ui.video(cx, ids!(ip_video));
        let busy = !video.is_unprepared();
        cx.stop_timer(self.inline.tick);
        cx.stop_timer(self.inline.hide);
        self.inline = Inline { key: key.clone(), url, playing: true, ..Inline::default() };
        ACTIVE.with(|a| *a.borrow_mut() = Some((key, self.ui.widget(cx, ids!(ip_box)))));
        // Hidden until this file is ready: until then it shows the last one's frame.
        let mut v = self.ui.widget(cx, ids!(ip_video));
        script_apply_eval!(cx, v, {draw_bg +: {opacity: 0.0}});
        if busy {
            if !video.is_cleaning_up() {
                video.stop_and_cleanup_resources(cx);
            }
            self.inline.restart_at = Some(0);
        } else {
            self.inline_begin(cx);
        }
        let bar = self.ui.widget(cx, ids!(ip_bar));
        self.inline.portrait = portrait(dims_of(&self.inline.url));
        shape_bar(cx, &bar, self.inline.portrait);
        self.ui.view(cx, ids!(ip_vol_pop)).set_visible(cx, false);
        // The pointer is on it (it was just clicked): the bar is in already.
        self.inline.bar_t = 1.0;
        self.inline_bar(cx, true);
        self.inline.tick = cx.start_interval(0.25);
        self.refresh_inline(cx);
        self.inline_relayout(cx);
    }

    fn inline_begin(&mut self, cx: &mut Cx) {
        let video = self.ui.video(cx, ids!(ip_video));
        video.set_source(crate::media_cache::source(&self.inline.url));
        video.begin_playback(cx);
        video.set_volume(cx, if self.viewer.muted { 0.0 } else { self.viewer.volume });
    }

    /// Stops and lets go of the video (another channel, mostly).
    pub(crate) fn stop_inline(&mut self, cx: &mut Cx) {
        if self.inline.key.is_empty() {
            return;
        }
        self.inline_fullscreen(cx, false);
        let video = self.ui.video(cx, ids!(ip_video));
        if !video.is_unprepared() && !video.is_cleaning_up() {
            video.stop_and_cleanup_resources(cx);
        }
        cx.stop_timer(self.inline.tick);
        cx.stop_timer(self.inline.hide);
        self.inline = Inline::default();
        ACTIVE.with(|a| *a.borrow_mut() = None);
        self.inline_relayout(cx);
    }

    /// The rows draw the player (or the card again): lay them out anew.
    pub(crate) fn inline_relayout(&mut self, cx: &mut Cx) {
        crate::lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(messages.list)));
        if FULL.get() {
            self.ui.widget(cx, ids!(ip_full)).redraw(cx);
        }
    }

    fn inline_toggle(&mut self, cx: &mut Cx) {
        let video = self.ui.video(cx, ids!(ip_video));
        if self.inline.ended {
            self.inline_restart(cx, 0);
        } else if self.inline.playing {
            video.pause_playback(cx);
            self.inline.playing = false;
            // Rails: paused part-way, the bar stays.
            self.inline.pinned = true;
        } else {
            video.resume_playback(cx);
            self.inline.playing = true;
            self.inline.pinned = false;
        }
        self.inline_bar(cx, true);
        self.refresh_inline(cx);
    }

    /// Plays a finished video again from `at_ms` (GStreamer at its end takes
    /// no seek or resume, so the player is reloaded; see media_view).
    fn inline_restart(&mut self, cx: &mut Cx, at_ms: u64) {
        self.inline.restart_at = Some(at_ms);
        self.inline.seek_shown = (at_ms > 0).then_some((at_ms, Some(std::time::Instant::now())));
        self.ui.video(cx, ids!(ip_video)).stop_and_cleanup_resources(cx);
        self.inline.moved = false;
        self.inline.ended = false;
        self.inline.playing = true;
        self.inline.pinned = false;
    }

    /// Slides the bar in or out; in while playing, it leaves again in 2s.
    fn inline_bar(&mut self, cx: &mut Cx, show: bool) {
        cx.stop_timer(self.inline.hide);
        if show && self.inline.playing {
            self.inline.hide = cx.start_timeout(2.0);
        }
        self.inline.bar_shown = show;
        self.animate_inline(cx);
    }

    /// Starts the frame loop if the bar or the big button has somewhere to go.
    fn animate_inline(&mut self, cx: &mut Cx) {
        let i = &self.inline;
        let big_target = if i.playing && !i.ended { 0.0 } else { 1.0 };
        let moving = i.bar_t != if i.bar_shown { 1.0 } else { 0.0 } || i.big_t != big_target;
        if moving && self.inline.anim_at.is_none() {
            self.inline.anim_at = Some(std::time::Instant::now());
            self.inline.anim = cx.new_next_frame();
        }
        self.refresh_inline(cx);
    }

    /// One frame: Rails slides and fades the bar over 0.25s, fades the big
    /// button over 0.2s.
    fn step_inline(&mut self, cx: &mut Cx) {
        let now = std::time::Instant::now();
        let dt = self.inline.anim_at.map_or(0.0, |t| (now - t).as_secs_f64());
        let i = &mut self.inline;
        let toward = |v: f64, target: f64, secs: f64| {
            let step = dt / secs;
            if target > v { (v + step).min(target) } else { (v - step).max(target) }
        };
        i.bar_t = toward(i.bar_t, if i.bar_shown { 1.0 } else { 0.0 }, SLIDE_SECS);
        let big_target = if i.playing && !i.ended { 0.0 } else { 1.0 };
        i.big_t = toward(i.big_t, big_target, BIG_FADE_SECS);
        let done = i.bar_t == if i.bar_shown { 1.0 } else { 0.0 } && i.big_t == big_target;
        i.anim_at = (!done).then_some(now);
        if !done {
            i.anim = cx.new_next_frame();
        }
        self.refresh_inline(cx);
    }

    /// Paints the player: the bar where its slide is, the big button's fade.
    fn refresh_inline(&mut self, cx: &mut Cx) {
        let video = self.ui.video(cx, ids!(ip_video));
        let i = &self.inline;
        let (pos, total) = (video.current_position_ms(), i.duration_ms);
        let pos = i.seek_shown.map_or(pos, |(at, _)| at as u128);
        let volume = if self.viewer.muted { 0.0 } else { self.viewer.volume };
        let eased = ease(i.bar_t);
        let look = BarLook {
            pos: if total > 0 { pos } else { 0 },
            total,
            playing: i.playing && !i.ended,
            volume,
            grow: i.seek_hover || i.seeking,
            alpha: eased,
            hover: i.hover_btn,
        };
        let bar = self.ui.widget(cx, ids!(ip_bar));
        paint_bar(cx, &bar, &look);
        // Rails slides it down its own height; set after painting (painting
        // the bar re-applies its style).
        let bar = self.ui.view(cx, ids!(ip_bar));
        let h = bar.area().rect(cx).size.y.max(36.0);
        bar.set_visible(cx, eased > 0.0);
        if let Some(mut v) = bar.borrow_mut() {
            v.walk.margin.bottom = -h * (1.0 - eased);
        }
        let mut vbar = self.ui.widget(cx, ids!(ip_vol_vbar));
        script_apply_eval!(cx, vbar, {draw_bg +: {fill: #(volume)}});
        let big = self.inline.big_t as f32;
        self.ui.view(cx, ids!(ip_big)).set_visible(cx, big > 0.0);
        for (path, c) in [(ids!(ip_big.play.tri), vec4(1.0, 1.0, 1.0, big)), (ids!(ip_big.play.shadow), vec4(0.0, 0.0, 0.0, 0.25 * big))] {
            let mut ico = self.ui.widget(cx, path);
            script_apply_eval!(cx, ico, {draw_icon +: {color: #(c)}});
        }
        self.ui.view(cx, ids!(ip_box)).redraw(cx);
    }

    /// Rails' mousemove and mouseleave: moving over the video brings the bar
    /// in (and, while playing, out again 2s later); leaving takes it away
    /// unless it's pinned by a pause part-way. A drag in progress keeps it.
    fn inline_pointer(&mut self, cx: &mut Cx, at: Option<DVec2>) {
        let was = std::mem::replace(&mut self.inline.inside, at.is_some());
        let bar = self.ui.widget(cx, ids!(ip_bar));
        let hover = at.filter(|_| self.inline.bar_t > 0.0).and_then(|abs| button_at(cx, &bar, abs));
        if hover != self.inline.hover_btn {
            self.inline.hover_btn = hover;
            self.refresh_inline(cx);
        }
        let dragging = self.inline.seeking || self.inline.vol_dragging;
        if at.is_some() {
            self.inline_bar(cx, true);
        } else if was && !dragging && !self.inline.vol_pop && (self.inline.playing || !self.inline.pinned) {
            self.inline_bar(cx, false);
        }
    }

    /// Shows the volume popup centred above the volume button, or hides it.
    fn inline_vol_pop(&mut self, cx: &mut Cx, show: bool) {
        cx.stop_timer(self.inline.vol_pop_hide);
        self.inline.vol_pop_hide = Timer::empty();
        let show = show && self.inline.portrait && self.inline.bar_t > 0.0;
        self.inline.vol_pop = show;
        let pop = self.ui.view(cx, ids!(ip_vol_pop));
        if show {
            let frame = self.ui.view(cx, ids!(ip_box)).area().rect(cx);
            let button = self.ui.view(cx, ids!(ip_bar.vol)).area().rect(cx);
            // 14px track + 6px padding each side; 80px + 10px each end.
            let (w, h) = (26.0, 100.0);
            let left = button.pos.x + button.size.x / 2.0 - w / 2.0 - frame.pos.x;
            // Rails: bottom 52px, just above the bar.
            let top = frame.size.y - 52.0 - h;
            if let Some(mut v) = pop.borrow_mut() {
                v.walk.margin.left = left.max(0.0);
                v.walk.margin.top = top.max(0.0);
            }
        }
        pop.set_visible(cx, show);
        self.ui.view(cx, ids!(ip_box)).redraw(cx);
    }

    fn inline_volume(&mut self, cx: &mut Cx) {
        let v = if self.viewer.muted { 0.0 } else { self.viewer.volume };
        self.ui.video(cx, ids!(ip_video)).set_volume(cx, v);
        self.refresh_inline(cx);
    }

    /// Rails' fullscreen button: the playing video fills the window, and the
    /// window the screen; again (or Esc) puts both back. The same player
    /// keeps going, drawn by the fullscreen layer instead of its message.
    pub(crate) fn inline_fullscreen(&mut self, cx: &mut Cx, on: bool) {
        if FULL.get() == on || on && self.inline.key.is_empty() {
            return;
        }
        FULL.set(on);
        let window = self.ui.window(cx, ids!(main_window));
        // INFERNO_TEST_NO_OS_FULLSCREEN: tests fill the window, not the screen.
        let os = std::env::var_os("INFERNO_TEST_NO_OS_FULLSCREEN").is_none();
        if os && on != window.is_fullscreen(cx) {
            if on {
                window.fullscreen(cx);
            } else {
                window.disable_fullscreen(cx);
            }
        }
        if !on {
            // Back in its message: the video fills the player again.
            if let Some(mut frame) = self.ui.view(cx, ids!(ip_frame)).borrow_mut() {
                frame.walk.width = Size::fill();
                frame.walk.height = Size::fill();
                frame.walk.margin.left = 0.0;
                frame.walk.margin.top = 0.0;
            }
            if let Some(mut host) = self.ui.widget(cx, ids!(ip_full)).borrow_mut::<InlineFullHost>() {
                host.fitted = None;
            }
        }
        self.inline_corners(cx);
        // The pointer is where it was; the bar is in, as after a move.
        self.inline_bar(cx, true);
        // The layer draws nothing until now, so it has nothing to redraw.
        self.ui.redraw(cx);
        self.inline_relayout(cx);
    }

    /// Whether a menu or card floating over the messages is at `abs`.
    fn popup_at(&self, cx: &mut Cx, abs: DVec2) -> bool {
        let open_at = |layer: &[LiveId], panel: &[LiveId], cx: &mut Cx| {
            self.ui.view(cx, layer).visible() && self.ui.view(cx, panel).area().rect(cx).contains(abs)
        };
        open_at(ids!(ctx_layer), ids!(ctx_menu), cx) || open_at(ids!(card_layer), ids!(card), cx)
    }

    /// Rounded in its message, square in fullscreen: the picture and the bar.
    fn inline_corners(&mut self, cx: &mut Cx) {
        let r = if FULL.get() { 0.0 } else { 8.0 };
        self.ui.video(cx, ids!(ip_video)).set_bg_instance(cx, live_id!(radius), &[r]);
        let mut bar = self.ui.widget(cx, ids!(ip_bar));
        script_apply_eval!(cx, bar, {draw_bg +: {radius: #(r)}});
    }

    /// After a theme switch (it restyles everything from the DSL): put the
    /// players' bars back as they were, in the new colours.
    pub(crate) fn repaint_players(&mut self, cx: &mut Cx) {
        reload_posters(cx);
        if !self.inline.key.is_empty() {
            let bar = self.ui.widget(cx, ids!(ip_bar));
            shape_bar(cx, &bar, self.inline.portrait);
            self.inline_corners(cx);
            self.refresh_inline(cx);
        }
        self.repaint_viewer(cx);
    }

    pub(crate) fn inline_is_fullscreen(&self) -> bool {
        FULL.get()
    }

    pub(crate) fn inline_handle_actions(&mut self, cx: &mut Cx, actions: &Actions) {
        if posters_handle_actions(cx, actions) {
            self.inline_relayout(cx);
        }
        if self.inline.key.is_empty() {
            return;
        }
        let uid = self.ui.widget(cx, ids!(ip_video)).widget_uid();
        for action in actions {
            let Some(wa) = action.as_widget_action() else { continue };
            if wa.widget_uid != uid {
                continue;
            }
            match wa.cast::<VideoAction>() {
                VideoAction::PlayerReset if self.inline.restart_at.is_some() => self.inline_begin(cx),
                VideoAction::PlaybackPrepared => {
                    let video = self.ui.video(cx, ids!(ip_video));
                    let total = video.total_duration_ms();
                    self.inline.duration_ms = total;
                    let url = self.inline.url.clone();
                    let (w, h) = video.video_size();
                    let shape = (w > 0 && h > 0).then_some((w as f64, h as f64));
                    if let Some((w, h)) = shape {
                        let new = dims_of(&url) != Some((w, h));
                        DIMS.with(|d| d.borrow_mut().insert(url, (w, h)));
                        let bar = self.ui.widget(cx, ids!(ip_bar));
                        self.inline.portrait = portrait(Some((w, h)));
                        shape_bar(cx, &bar, self.inline.portrait);
                        if new {
                            self.inline_relayout(cx);
                        }
                    }
                    let mut v = self.ui.widget(cx, ids!(ip_video));
                    script_apply_eval!(cx, v, {draw_bg +: {opacity: 1.0}});
                    if self.inline.restart_at == Some(0) {
                        self.inline.restart_at = None;
                    }
                    self.refresh_inline(cx);
                }
                // Only an end reached by playing counts (see media_view).
                VideoAction::PlaybackCompleted => {
                    let video = self.ui.video(cx, ids!(ip_video));
                    let total = self.inline.duration_ms;
                    if self.inline.moved && total > 0 && video.current_position_ms() + 1000 >= total {
                        self.inline_ended(cx);
                    }
                }
                _ => {}
            }
        }
    }

    /// Rails at the end: the big button back, the bar away.
    fn inline_ended(&mut self, cx: &mut Cx) {
        self.inline.ended = true;
        self.inline.playing = false;
        self.inline.pinned = false;
        self.inline_bar(cx, false);
        self.refresh_inline(cx);
    }

    /// The seek bar showing (portrait videos have it on its own row).
    fn inline_seek_path(&mut self, cx: &mut Cx) -> &'static [LiveId] {
        if self.ui.view(cx, ids!(ip_bar.seek_top)).visible() { ids!(ip_bar.seek_top) } else { ids!(ip_bar.seek) }
    }

    /// Before the UI, like the viewer: the player's own presses come first.
    pub(crate) fn inline_handle_event(&mut self, cx: &mut Cx, event: &Event) {
        // The first-frame players live in the host; hand them over once.
        if !posters_set() {
            let players = [
                ids!(ip_host.posters.p0), ids!(ip_host.posters.p1), ids!(ip_host.posters.p2), ids!(ip_host.posters.p3),
                ids!(ip_host.posters.p4), ids!(ip_host.posters.p5), ids!(ip_host.posters.p6), ids!(ip_host.posters.p7),
            ];
            set_posters(players.iter().map(|p| self.ui.widget(cx, &p[..])).collect());
        }
        if self.inline.key.is_empty() {
            return;
        }
        if self.inline.anim.is_event(event).is_some() {
            self.step_inline(cx);
        }
        if self.inline.tick.is_event(event).is_some() {
            // The end isn't always reported: a position stopped at the end is
            // the end too (see media_view).
            let video = self.ui.video(cx, ids!(ip_video));
            let (pos, total) = (video.current_position_ms(), self.inline.duration_ms);
            if let Some(at) = self.inline.restart_at.filter(|_| pos > 0) {
                self.inline.restart_at = None;
                video.seek_to(cx, at);
            }
            let last = self.inline.last_pos;
            self.inline.moved |= pos > last && pos < last.saturating_add(2000);
            let stalled = self.inline.moved && pos == last && total > 0 && pos + 1000 >= total;
            if self.inline.playing && stalled && self.inline.restart_at.is_none() {
                self.inline_ended(cx);
            }
            self.inline.last_pos = pos;
            if let Some((at, Some(since))) = self.inline.seek_shown {
                if pos.abs_diff(at as u128) < 1500 || since.elapsed().as_secs_f64() > 2.0 {
                    self.inline.seek_shown = None;
                }
            }
            if self.inline.playing || self.inline.bar_t > 0.0 {
                self.refresh_inline(cx);
            }
        }
        if self.inline.hide.is_event(event).is_some() && self.inline.playing && !self.inline.seeking && !self.inline.vol_pop {
            self.inline_bar(cx, false);
        }
        if self.inline.vol_pop_hide.is_event(event).is_some() {
            self.inline.vol_pop_hide = Timer::empty();
            if !self.inline.vol_dragging {
                self.inline_vol_pop(cx, false);
            }
        }
        if self.inline.bar_t <= 0.0 && self.inline.vol_pop {
            self.inline_vol_pop(cx, false);
        }
        // A menu or card open over the player takes its own clicks (the
        // player's hit tests below would claim them first).
        let at = match event {
            Event::MouseDown(m) => Some(m.abs),
            Event::MouseUp(m) => Some(m.abs),
            Event::MouseMove(m) => Some(m.abs),
            _ => None,
        };
        if at.is_some_and(|p| self.popup_at(cx, p)) {
            if self.inline.inside {
                self.inline_pointer(cx, None);
            }
            self.inline.pressed = None;
            return;
        }
        if !on_screen() {
            // Scrolled away from under the pointer: it has left.
            if self.inline.inside {
                self.inline_pointer(cx, None);
            }
            return;
        }
        // A portrait video's volume: over the button, the popup; a press on
        // its track sets the volume and follows the pointer until let go.
        // Rails waits 200ms after leaving before it hides.
        if self.inline.portrait && self.inline.bar_t > 0.0 {
            // Hover by position: asking for hits would claim presses meant
            // for the button and the slider.
            if let Event::MouseMove(m) = event {
                let button = self.ui.view(cx, ids!(ip_bar.vol)).area().rect(cx);
                let pop = self.ui.view(cx, ids!(ip_vol_pop)).area().rect(cx);
                let over = button.contains(m.abs) || self.inline.vol_pop && pop.contains(m.abs);
                if over && !self.inline.vol_pop {
                    self.inline_vol_pop(cx, true);
                } else if over {
                    cx.stop_timer(self.inline.vol_pop_hide);
                    self.inline.vol_pop_hide = Timer::empty();
                } else if self.inline.vol_pop && !self.inline.vol_dragging && self.inline.vol_pop_hide.is_empty() {
                    self.inline.vol_pop_hide = cx.start_timeout(0.2);
                }
            }
            if self.inline.vol_pop {
                let track = self.ui.view(cx, ids!(ip_vol_vbar)).area();
                let r = track.rect(cx);
                let at = |abs: DVec2| (1.0 - (abs.y - r.pos.y) / r.size.y.max(1.0)).clamp(0.0, 1.0);
                let level = match event.hits(cx, track) {
                    Hit::FingerDown(fe) if fe.device.is_primary_hit() => Some(at(fe.abs)),
                    Hit::FingerMove(fe) => Some(at(fe.abs)),
                    Hit::FingerUp(fe) => {
                        self.inline.vol_dragging = false;
                        if !fe.is_over {
                            self.inline.vol_pop_hide = cx.start_timeout(0.2);
                        }
                        None
                    }
                    Hit::FingerHoverIn(_) | Hit::FingerHoverOver(_) => {
                        cx.set_cursor(MouseCursor::Hand);
                        None
                    }
                    _ => None,
                };
                if let Some(v) = level {
                    self.inline.vol_dragging = true;
                    self.viewer.volume = v;
                    self.viewer.muted = v <= 0.0;
                    self.inline_volume(cx);
                    self.inline_bar(cx, true);
                }
            }
        }
        // Seeking and the volume: press, then drag anywhere until let go.
        if self.inline.bar_t > 0.0 {
            let seek_path = self.inline_seek_path(cx);
            let bars: [(&[LiveId], bool); 2] = [(seek_path, true), (ids!(ip_bar.vol_bar), false)];
            for (path, seek) in bars {
                let area = self.ui.view(cx, path).area();
                let r = area.rect(cx);
                let at = |abs: DVec2| ((abs.x - r.pos.x) / r.size.x.max(1.0)).clamp(0.0, 1.0);
                let frac = match event.hits(cx, area) {
                    Hit::FingerDown(fe) if fe.device.is_primary_hit() => Some(at(fe.abs)),
                    Hit::FingerMove(fe) => Some(at(fe.abs)),
                    Hit::FingerUp(fe) => {
                        self.inline.seeking = false;
                        let total = self.inline.duration_ms;
                        if let (true, Some((at, None))) = (seek, self.inline.seek_shown) {
                            self.inline.seek_shown = Some((at, Some(std::time::Instant::now())));
                            // To the very end is the end (a player sent there
                            // takes no resume; see media_view).
                            if at as u128 + 300 >= total {
                                self.inline.seek_shown = Some((total as u64, None));
                                if !self.inline.ended {
                                    self.ui.video(cx, ids!(ip_video)).pause_playback(cx);
                                    self.inline_ended(cx);
                                }
                            } else if self.inline.ended {
                                self.inline_restart(cx, at);
                            } else {
                                self.ui.video(cx, ids!(ip_video)).seek_to(cx, at);
                            }
                        }
                        self.inline.seek_hover = seek && fe.is_over;
                        let frame = self.ui.view(cx, ids!(ip_box)).area().rect(cx);
                        let inside = frame.contains(fe.abs);
                        self.inline_bar(cx, inside || !self.inline.playing);
                        self.refresh_inline(cx);
                        None
                    }
                    Hit::FingerHoverIn(_) | Hit::FingerHoverOver(_) => {
                        cx.set_cursor(MouseCursor::Hand);
                        if seek && !self.inline.seek_hover {
                            self.inline.seek_hover = true;
                            self.refresh_inline(cx);
                        }
                        None
                    }
                    Hit::FingerHoverOut(_) if seek => {
                        self.inline.seek_hover = false;
                        self.refresh_inline(cx);
                        None
                    }
                    _ => None,
                };
                let Some(f) = frac else { continue };
                self.inline.seeking = true;
                if seek {
                    let total = self.inline.duration_ms;
                    if total > 0 {
                        self.inline.seek_shown = Some(((f * total as f64) as u64, None));
                    }
                    self.refresh_inline(cx);
                } else {
                    self.viewer.volume = f;
                    self.viewer.muted = f <= 0.0;
                    self.inline_volume(cx);
                }
            }
        }
        // Over the video: the bar. A click on a button presses it, anywhere
        // else plays or pauses.
        //
        // Hover is by position: Makepad gives a hover to one area at a time,
        // so the bar's own sliders would take it from the player and it would
        // count as the pointer leaving.
        let area = self.ui.view(cx, ids!(ip_box)).area();
        let rect = |ui: &WidgetRef, cx: &mut Cx, path: &[LiveId]| ui.view(cx, path).area().rect(cx);
        match event {
            Event::MouseMove(m) => {
                let inside = area.clipped_rect(cx).contains(m.abs);
                self.inline_pointer(cx, inside.then_some(m.abs));
            }
            Event::MouseLeave(_) => self.inline_pointer(cx, None),
            _ => {}
        }
        match event.hits(cx, area) {
            Hit::FingerHoverIn(_) | Hit::FingerHoverOver(_) => cx.set_cursor(MouseCursor::Hand),
            Hit::FingerDown(fe) if fe.device.is_primary_hit() => self.inline.pressed = Some(fe.abs),
            // A click, however long it's held: only moving off it, or
            // dragging, isn't one.
            Hit::FingerUp(fe) if fe.is_over && self.inline.pressed.take().is_some_and(|p| (fe.abs - p).length() < 8.0) => {
                let on = |path: &[LiveId], ui: &WidgetRef, cx: &mut Cx| rect(ui, cx, path).contains(fe.abs);
                let shown = self.inline.bar_t > 0.5;
                if shown && on(ids!(ip_bar.vol), &self.ui, cx) {
                    self.viewer.muted = !self.viewer.muted || self.viewer.volume <= 0.0;
                    if !self.viewer.muted && self.viewer.volume <= 0.0 {
                        self.viewer.volume = 1.0;
                    }
                    self.inline_volume(cx);
                } else if shown && on(ids!(ip_bar.fs), &self.ui, cx) {
                    self.inline_fullscreen(cx, !FULL.get());
                } else if shown && on(ids!(ip_bar), &self.ui, cx) && !on(ids!(ip_bar.play_btn), &self.ui, cx) {
                    // The bar between its buttons.
                } else {
                    self.inline_toggle(cx);
                }
            }
            Hit::FingerUp(_) => self.inline.pressed = None,
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cards_fit_rails_box_and_keys_follow_rows() {
        assert_eq!(card_size(Some((1920.0, 1080.0))), (512.0, 288.0));
        assert_eq!(card_size(Some((1080.0, 1920.0))), (216.0, 384.0), "portrait: max-h-96");
        assert_eq!(card_size(Some((320.0, 240.0))), (320.0, 240.0), "never enlarged");
        assert_eq!(card_size(None), (400.0, 225.0));
        assert_eq!(key("u"), "", "outside the list: no inline player");
        set_row("abc");
        assert_eq!(key("u"), "abc|u");
        set_row("");
        assert!(player_for("").is_none());
    }
}
