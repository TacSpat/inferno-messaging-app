//! Rails' voice channel screen (channels/_voice_content): a grid of cards,
//! one per person in the channel, over gray-950, with the Join Voice /
//! Voice Connected bar under it. Before anyone volunteers as a provider it
//! says "Voice Not Available"; with nobody in, the channel's name and "No
//! one is in this channel yet."
//!
//! The grid follows Rails' CSS: 12px gaps, as many 180px-or-wider columns
//! as fit, 4:3 cards; one to four people get fixed layouts (1, 2, 3 and 2×2
//! columns, at most 400/600/800/600px wide, centred).

use std::collections::HashMap;

use makepad_widgets::*;

use crate::backend::VoicePerson;
use crate::lists::rgba;

/// Cards the template holds; more people than this show the first ones.
pub const SLOTS: usize = 24;
/// Stream tiles the template holds (`st0`..`st3`).
pub const STREAM_SLOTS: usize = 4;

/// Someone sharing their screen.
#[derive(Debug, Clone, PartialEq)]
pub struct StreamTile {
    pub pubkey: String,
    pub name: String,
    pub watching: bool,
}

/// Draws `tex` (if any) into an Image and a GPU view standing in the same
/// place, showing whichever fits it.
pub fn show_video(cx: &mut Cx, img: &ImageRef, yuv: &WidgetRef, tex: Option<&VideoTex>) {
    match tex {
        Some(VideoTex::Bgra(t)) => {
            img.set_texture(cx, Some(t.clone()));
            img.set_visible(cx, true);
            yuv.set_visible(cx, false);
        }
        Some(VideoTex::Yuv { y, u, v, width, height }) => {
            let (vw, vh) = (*width as f64, *height as f64);
            let mut w = yuv.clone();
            script_apply_eval!(cx, w, {draw_bg +: {vw: #(vw) vh: #(vh)}});
            if let Some(mut view) = yuv.borrow_mut::<View>() {
                view.draw_bg.draw_vars.set_texture(0, y);
                view.draw_bg.draw_vars.set_texture(1, u);
                view.draw_bg.draw_vars.set_texture(2, v);
            }
            yuv.set_visible(cx, true);
            img.set_visible(cx, false);
        }
        None => {
            img.set_visible(cx, false);
            yuv.set_visible(cx, false);
        }
    }
}
const GAP: f64 = 12.0;
const MIN_CARD: f64 = 180.0;

/// Someone's camera, ready to draw: one BGRA texture, or the Y, U and V
/// planes for the card's GPU shader.
#[derive(Clone, Debug)]
pub enum VideoTex {
    Bgra(Texture),
    Yuv { y: Texture, u: Texture, v: Texture, width: usize, height: usize },
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub enum Status {
    /// Not in this channel: Rails' green "Join Voice".
    #[default]
    Join,
    Connecting,
    Connected,
}

#[derive(Debug, Clone, PartialEq)]
pub enum VoiceViewAction {
    Join,
    ToggleChat,
    Watch(String),
    StopWatching(String),
    Focus(String),
    Unfocus,
    Fullscreen(String),
    OpenSettings,
    None,
}

#[derive(Script, ScriptHook, Widget)]
pub struct VoiceView {
    #[deref]
    view: View,
    #[rust]
    pub channel_id: String,
    #[rust]
    pub name: String,
    #[rust]
    pub people: Vec<VoicePerson>,
    /// Voice is on and has a provider (Rails' `voice_configured`).
    #[rust]
    pub ready: bool,
    /// May open the server's voice settings.
    #[rust]
    pub admin: bool,
    #[rust]
    pub status: Status,
    /// Who is speaking (pubkey hex) and how loud (0..1).
    #[rust]
    pub levels: HashMap<String, f32>,
    /// Camera video by pubkey hex: shown in the card instead of the avatar.
    #[rust]
    pub videos: HashMap<String, VideoTex>,
    /// Who is sharing their screen, and whether we watch.
    #[rust]
    pub streams: Vec<StreamTile>,
    /// Their screens (watched ones), by pubkey hex.
    #[rust]
    pub stream_videos: HashMap<String, VideoTex>,
    /// The stream shown large (Rails' theater mode).
    #[rust]
    pub focus: Option<String>,
    /// The channel has a chat to open (not the AFK channel).
    #[rust]
    pub chat_available: bool,
    /// The chat is open beside the cards: Rails' compact grid.
    #[rust]
    pub compact: bool,
    /// What each card slot was last styled with: unchanged cards skip
    /// restyling (most frames only a glow moves).
    #[rust]
    applied: Vec<Option<String>>,
    /// The grid's width last frame, which this frame's cards are sized to.
    #[rust]
    width: f64,
}

/// Rails' columns and maximum width for `n` cards in `avail` points; with
/// the chat open, its compact grid (.voice-compact).
fn layout(n: usize, avail: f64, compact: bool) -> (usize, f64) {
    let fixed = match (n, compact) {
        (1, false) => Some((1, 400.0)),
        (2, false) => Some((2, 600.0)),
        (3, false) => Some((3, 800.0)),
        (4, false) => Some((2, 600.0)),
        (1, true) => Some((1, 280.0)),
        (2..=4, true) => Some((2, 420.0)),
        _ => None,
    };
    let (gap, min) = if compact { (8.0, 140.0) } else { (GAP, MIN_CARD) };
    match fixed {
        Some((cols, max)) => (cols, avail.min(max)),
        None => (((avail + gap) / (min + gap)).floor().max(1.0) as usize, avail),
    }
}

/// `a` mixed toward `b` by `t` (CSS color-mix).
fn mix(a: u32, b: u32, t: f32) -> Vec4 {
    let (x, y) = (rgba(a, 1.0), rgba(b, 1.0));
    vec4(x.x + (y.x - x.x) * t, x.y + (y.y - x.y) * t, x.z + (y.z - x.z) * t, 1.0)
}

impl VoiceView {
    fn apply(&mut self, cx: &mut Cx) {
        let view = &self.view;
        let some = !self.people.is_empty();
        view.view(cx, ids!(unavailable)).set_visible(cx, !self.ready);
        view.view(cx, ids!(empty)).set_visible(cx, self.ready && !some && self.streams.is_empty());
        let streaming = !self.streams.is_empty();
        view.widget(cx, ids!(grid)).set_visible(cx, self.ready && (some || streaming));
        view.view(cx, ids!(status)).set_visible(cx, self.ready);
        view.view(cx, ids!(chat_btn)).set_visible(cx, self.chat_available);
        view.view(cx, ids!(unavailable.settings_btn)).set_visible(cx, self.admin);
        view.widget(cx, ids!(unavailable.ask_admin)).set_visible(cx, !self.admin);
        view.label(cx, ids!(empty.empty_name)).set_text(cx, &self.name);
        view.view(cx, ids!(status.join_btn)).set_visible(cx, self.status == Status::Join);
        view.view(cx, ids!(status.connecting)).set_visible(cx, self.status == Status::Connecting);
        view.view(cx, ids!(status.connected)).set_visible(cx, self.status == Status::Connected);
        // Theater: the focused stream large, the cards in a strip below.
        let focus = self.focus.clone().filter(|f| self.streams.iter().any(|s| &s.pubkey == f && s.watching));
        view.view(cx, ids!(focus_area)).set_visible(cx, focus.is_some());
        if let Some(mut grid) = view.widget(cx, ids!(grid)).borrow_mut::<View>() {
            grid.walk.height = if focus.is_some() { Size::Fixed(190.0) } else { Size::fill() };
        }
        if let Some(f) = &focus {
            let name = self.streams.iter().find(|s| &s.pubkey == f).map(|s| s.name.clone()).unwrap_or_default();
            view.label(cx, ids!(focus_area.fv_label)).set_text(cx, &format!("{name}'s screen"));
            let img = view.image(cx, ids!(focus_area.fv_img));
            let yuv = view.widget(cx, ids!(focus_area.fv_yuv));
            show_video(cx, &img, &yuv, self.stream_videos.get(f));
        }
        if !(self.ready && (some || streaming)) {
            return;
        }

        // Stream tiles first (the focused one is up top instead).
        let tiles: Vec<StreamTile> = self.streams.iter().filter(|s| Some(&s.pubkey) != focus.as_ref()).take(STREAM_SLOTS).cloned().collect();
        let shown = (self.people.len().min(SLOTS) + tiles.len()).max(1);
        // Under a focused stream the cards are a strip: Rails' compact size.
        let compact = self.compact || focus.is_some();
        let gap = if compact { 8.0 } else { GAP };
        let avail = (self.width - 2.0 * GAP).max(80.0);
        let (mut cols, total) = layout(shown, avail, compact);
        let mut card_w = ((total - gap * (cols as f64 - 1.0)) / cols as f64).floor();
        if focus.is_some() {
            // One row under the stream, as tall as its strip allows.
            cols = shown;
            card_w = ((avail - gap * (cols as f64 - 1.0)) / cols as f64).min(170.0).floor();
        }
        // 4:3, or Rails' compact 5:4.
        let card_h = if compact { (card_w * 4.0 / 5.0).floor() } else { (card_w * 3.0 / 4.0).floor() };
        // Each card's widget is 14px bigger on every side (its glow), less
        // margins that leave `gap` between cards.
        let row_w = cols as f64 * (card_w + gap);
        let (box_w, box_h) = (card_w + 28.0, card_h + 28.0);
        let m = -(14.0 - gap / 2.0);
        // Rails' avatar: 6rem, 4.5rem compact.
        let (face, font) = if compact { (72.0, 18.0) } else { (96.0, 24.0) };
        let mut cards = view.widget(cx, ids!(grid.cards));
        script_apply_eval!(cx, cards, {width: #(row_w)});
        for i in 0..STREAM_SLOTS {
            let mut tile = view.widget(cx, &[id!(grid), id!(cards), LiveId::from_str(&format!("st{i}"))]);
            let Some(t) = tiles.get(i) else {
                tile.set_visible(cx, false);
                continue;
            };
            tile.set_visible(cx, true);
            script_apply_eval!(cx, tile, {width: #(box_w) height: #(box_h) margin: #(m)});
            tile.view(cx, ids!(waiting)).set_visible(cx, !t.watching);
            tile.view(cx, ids!(live)).set_visible(cx, t.watching);
            tile.label(cx, ids!(st_text)).set_text(cx, &format!("{} is streaming", t.name));
            tile.label(cx, ids!(st_label)).set_text(cx, &format!("{}'s screen", t.name));
            if t.watching {
                let img = tile.image(cx, ids!(sv_img));
                let yuv = tile.widget(cx, ids!(sv_yuv));
                show_video(cx, &img, &yuv, self.stream_videos.get(&t.pubkey));
            }
        }
        for i in 0..SLOTS {
            let mut card = view.widget(cx, &[id!(grid), id!(cards), LiveId::from_str(&format!("c{i}"))]);
            let Some(p) = self.people.get(i) else {
                card.set_visible(cx, false);
                if let Some(slot) = self.applied.get_mut(i) {
                    *slot = None;
                }
                continue;
            };
            card.set_visible(cx, true);
            let key = format!(
                "{}|{box_w}|{box_h}|{m}|{}|{:?}|{}|{}|{}|{}|{}",
                p.pubkey,
                p.avatar,
                self.levels.get(&p.pubkey),
                self.videos.contains_key(&p.pubkey),
                p.name,
                p.self_mute || p.server_mute,
                p.self_deaf || p.server_deaf,
                p.picture.as_deref().unwrap_or_default(),
            );
            if self.applied.len() <= i {
                self.applied.resize(i + 1, None);
            }
            if self.applied[i].as_deref() == Some(key.as_str()) && !self.videos.contains_key(&p.pubkey) {
                continue;
            }
            self.applied[i] = Some(key);
            let color = rgba(p.avatar, 1.0);
            // The ring fades in with the level; the glow follows it.
            let (speak, level) = match self.levels.get(&p.pubkey) {
                Some(l) => (((*l / 0.12).min(1.0)) as f64, l.min(1.0) as f64),
                None => (0.0, 0.0),
            };
            script_apply_eval!(cx, card, {width: #(box_w) height: #(box_h) margin: #(m) draw_bg +: {color: #(color) speak: #(speak) level: #(level)}});
            // Rails' fallback: the profile colour mixed with 20% white.
            let fallback = mix(p.avatar, 0xffffff, 0.2);
            let mut face_bg = card.widget(cx, ids!(face));
            let r = face / 2.0;
            script_apply_eval!(cx, face_bg, {width: #(face) height: #(face) draw_bg +: {color: #(fallback) border_radius: #(r)}});
            let mut pic_w = card.widget(cx, ids!(face.pic));
            script_apply_eval!(cx, pic_w, {width: #(face) height: #(face) draw_bg +: {border_radius: #(r)}});
            let mut initial_w = card.widget(cx, ids!(face.initial));
            script_apply_eval!(cx, initial_w, {draw_text +: {text_style +: {font_size: #(font)}}});
            let face = card.view(cx, ids!(face));
            let video = card.image(cx, ids!(video));
            let yuv = card.view(cx, ids!(yuv));
            match self.videos.get(&p.pubkey) {
                Some(VideoTex::Bgra(tex)) => {
                    video.set_texture(cx, Some(tex.clone()));
                    video.set_visible(cx, true);
                    yuv.set_visible(cx, false);
                    face.set_visible(cx, false);
                }
                Some(VideoTex::Yuv { y, u, v, width, height }) => {
                    let (vw, vh) = (*width as f64, *height as f64);
                    let mut w = card.widget(cx, ids!(yuv));
                    script_apply_eval!(cx, w, {draw_bg +: {vw: #(vw) vh: #(vh)}});
                    if let Some(mut view) = yuv.borrow_mut() {
                        view.draw_bg.draw_vars.set_texture(0, y);
                        view.draw_bg.draw_vars.set_texture(1, u);
                        view.draw_bg.draw_vars.set_texture(2, v);
                    }
                    yuv.set_visible(cx, true);
                    video.set_visible(cx, false);
                    face.set_visible(cx, false);
                }
                None => {
                    video.set_visible(cx, false);
                    yuv.set_visible(cx, false);
                    face.set_visible(cx, true);
                }
            }
            face.label(cx, ids!(initial)).set_text(cx, &p.initial);
            let pic = face.image(cx, ids!(pic));
            crate::images::show(cx, &pic, p.picture.as_deref());
            card.label(cx, ids!(pill.who)).set_text(cx, &p.name);
            let (muted, deaf) = (p.self_mute || p.server_mute, p.self_deaf || p.server_deaf);
            card.view(cx, ids!(badge_mute)).set_visible(cx, muted && !deaf);
            card.view(cx, ids!(badge_deaf)).set_visible(cx, deaf);
        }
    }

    /// Right-click on a card: whose, and where.
    pub fn context(&self, cx: &mut Cx, actions: &Actions) -> Option<(String, DVec2)> {
        (0..SLOTS.min(self.people.len())).find_map(|i| {
            let card = self.view.view(cx, &[id!(grid), id!(cards), LiveId::from_str(&format!("c{i}"))]);
            card.finger_down(actions).filter(|e| !e.device.is_primary_hit()).map(|e| (self.people[i].pubkey.clone(), e.abs))
        })
    }

    /// What was clicked.
    pub fn clicked(&self, cx: &mut Cx, actions: &Actions) -> VoiceViewAction {
        let up = |path: &[LiveId]| self.view.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled);
        if let Some(f) = self.focus.clone() {
            if up(ids!(focus_area.fv_unfocus)) {
                return VoiceViewAction::Unfocus;
            }
            if up(ids!(focus_area.fv_full)) {
                return VoiceViewAction::Fullscreen(f);
            }
            if up(ids!(focus_area.fv_stop)) {
                return VoiceViewAction::StopWatching(f);
            }
        }
        let tiles: Vec<&StreamTile> = self.streams.iter().filter(|s| Some(&s.pubkey) != self.focus.as_ref()).take(STREAM_SLOTS).collect();
        for (i, t) in tiles.iter().enumerate() {
            let tile = |name: LiveId| [id!(grid), id!(cards), LiveId::from_str(&format!("st{i}")), name];
            if up(&tile(id!(watch_btn))) {
                return VoiceViewAction::Watch(t.pubkey.clone());
            }
            if up(&tile(id!(st_stop))) {
                return VoiceViewAction::StopWatching(t.pubkey.clone());
            }
            if up(&tile(id!(st_full))) {
                return VoiceViewAction::Fullscreen(t.pubkey.clone());
            }
            if up(&tile(id!(st_focus))) || up(&tile(id!(live))) {
                return VoiceViewAction::Focus(t.pubkey.clone());
            }
        }
        if up(ids!(status.join_btn)) {
            VoiceViewAction::Join
        } else if up(ids!(chat_btn)) {
            VoiceViewAction::ToggleChat
        } else if up(ids!(unavailable.settings_btn)) {
            VoiceViewAction::OpenSettings
        } else {
            VoiceViewAction::None
        }
    }
}

impl Widget for VoiceView {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        self.apply(cx);
        let step = self.view.draw_walk(cx, scope, walk);
        // Cards are sized to the grid's width; when that changes (a resize,
        // the first frame), size them again next frame.
        let w = self.view.widget(cx, ids!(grid)).area().rect(cx).size.x;
        if w > 0.0 && (w - self.width).abs() > 0.5 {
            self.width = w;
            self.view.redraw(cx);
        }
        step
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rails_grid() {
        assert_eq!(layout(1, 1000.0, false), (1, 400.0));
        assert_eq!(layout(2, 500.0, false), (2, 500.0));
        assert_eq!(layout(4, 1000.0, false), (2, 600.0));
        // auto-fill minmax(180px, 1fr): 5 cards in 800px → 4 columns.
        assert_eq!(layout(5, 800.0, false).0, 4);
        assert_eq!(layout(9, 150.0, false).0, 1);
        // Compact (chat open): 3 people in two columns, at most 420px.
        assert_eq!(layout(3, 1000.0, true), (2, 420.0));
        assert_eq!(layout(5, 600.0, true).0, 4);
    }
}
