//! The message list: a `PortalList` that only builds the rows on screen, so
//! 10,000 messages cost the same per frame as 20. Rows come from the backend
//! already resolved; `INFERNO_DEMO=1` swaps in the 10,000-message synthetic
//! history for performance checks.

use makepad_widgets::*;

use crate::backend::MessageRow;
use crate::demo::{self, AUTHORS};
use crate::lists::rgba;

const DEMO_HISTORY: usize = 10_000;

#[derive(Script, ScriptHook, Widget)]
pub struct MessageList {
    #[deref]
    view: View,
    #[rust]
    rows: Vec<MessageRow>,
    /// Frames drawn since the channel opened; the jump to the newest message
    /// waits one frame so real row heights replace estimates first.
    #[rust]
    opened_frames: u32,
    #[rust]
    perf: Perf,
    /// Row under the pointer: the only one showing the hover toolbar.
    #[rust]
    hovered: Option<usize>,
    /// We may pin (manage_messages): shows the toolbar's pin button.
    #[rust]
    pub can_pin: bool,
    /// Row flashing after a jump, and when the flash started.
    #[rust]
    flash: Option<(usize, std::time::Instant)>,
}

/// What a click in the list asks the app to do.
#[derive(Debug, Clone, PartialEq)]
pub enum MessageAction {
    Reply(usize),
    Edit(usize),
    Pin(usize),
    /// Right-click on a row at a window position.
    Context(usize, DVec2),
    /// Click on the author's avatar or name, at a window position.
    Author(usize, DVec2),
}

/// Spec: a jumped-to message flashes accent/.3, fading over 4s.
const FLASH_SECS: f32 = 4.0;

/// Draw timings, printed once a second when INFERNO_PERF is set. Measures
/// the list's own CPU time per frame (row layout and text), which is what
/// grows with history size if virtualization isn't working.
#[derive(Default)]
struct Perf {
    enabled: Option<bool>,
    window_start: Option<std::time::Instant>,
    frames: u32,
    rows: u32,
    total: std::time::Duration,
    worst: std::time::Duration,
}

impl Perf {
    fn record(&mut self, took: std::time::Duration, rows: u32) {
        let enabled = *self.enabled.get_or_insert_with(|| std::env::var_os("INFERNO_PERF").is_some());
        if !enabled {
            return;
        }
        let now = std::time::Instant::now();
        let start = *self.window_start.get_or_insert(now);
        self.frames += 1;
        self.rows += rows;
        self.total += took;
        self.worst = self.worst.max(took);
        if now.duration_since(start).as_secs_f64() >= 1.0 {
            println!(
                "PERF frames={} avg_ms={:.2} worst_ms={:.2} rows_per_frame={:.1}",
                self.frames,
                self.total.as_secs_f64() * 1000.0 / self.frames as f64,
                self.worst.as_secs_f64() * 1000.0,
                self.rows as f64 / self.frames as f64,
            );
            *self = Perf { enabled: Some(true), ..Default::default() };
        }
    }
}

fn clock(at: i64) -> String {
    let secs = at.rem_euclid(86_400);
    let (h, m) = (secs / 3600, (secs / 60) % 60);
    let (h12, ampm) = match h {
        0 => (12, "AM"),
        1..=11 => (h, "AM"),
        12 => (12, "PM"),
        _ => (h - 12, "PM"),
    };
    format!("{h12}:{m:02} {ampm}")
}

/// The synthetic history as rows, for `INFERNO_DEMO=1`.
pub fn demo_rows() -> Vec<MessageRow> {
    let history = demo::history(DEMO_HISTORY);
    history
        .iter()
        .enumerate()
        .map(|(i, m)| {
            let a = &AUTHORS[m.author];
            MessageRow {
                id: String::new(),
                own: false,
                author_pk: String::new(),
                reply_to: None,
                author: a.name.into(),
                initial: a.name[..1].to_uppercase(),
                color: a.role_color,
                avatar: a.avatar_color,
                at: m.at,
                body: Some(m.body.clone()),
                reply: m.reply_to.map(|p| {
                    let cut: String = history[p].body.chars().take(60).collect();
                    format!("↳ {}  {}", AUTHORS[history[p].author].name, cut)
                }),
                edited: m.edited,
                pinned: false,
                grouped: demo::grouped(i.checked_sub(1).map(|p| &history[p]), m),
                system: m.system,
            }
        })
        .collect()
}

impl MessageList {
    /// Replaces the rows. A new channel opens at its newest message; the same
    /// channel keeps its scroll (and keeps following if it was at the end).
    pub fn set_rows(&mut self, cx: &mut Cx, rows: Vec<MessageRow>, new_channel: bool) {
        self.rows = rows;
        if new_channel {
            self.opened_frames = 0;
        }
        crate::lists::redraw_items(cx, &self.view.portal_list(cx, ids!(list)));
        self.view.redraw(cx);
    }

    pub fn row(&self, index: usize) -> Option<&MessageRow> {
        self.rows.get(index)
    }


    /// Scrolls to the message with event id `id` and flashes it.
    pub fn jump_to(&mut self, cx: &mut Cx, id: &str) -> bool {
        let Some(index) = self.rows.iter().position(|r| r.id == id) else { return false };
        let list = self.view.portal_list(cx, ids!(list));
        // Leave some room above so the message isn't flush with the header.
        list.smooth_scroll_to(cx, index, 80.0, Some(40), 120.0);
        self.flash = Some((index, std::time::Instant::now()));
        crate::lists::redraw_items(cx, &self.view.portal_list(cx, ids!(list)));
        self.view.redraw(cx);
        true
    }

    /// Handles hover and clicks inside the rows.
    pub fn handle_list_actions(&mut self, cx: &mut Cx, actions: &Actions) -> Option<MessageAction> {
        let list = self.view.portal_list(cx, ids!(list));
        let mut out = None;
        for (index, item) in list.items_with_actions(actions) {
            if item.as_view().finger_hover_in(actions).is_some() {
                self.hovered = Some(index);
                crate::lists::redraw_items(cx, &list);
            }
            if item.as_view().finger_hover_out(actions).is_some() && self.hovered == Some(index) {
                self.hovered = None;
                crate::lists::redraw_items(cx, &list);
            }
            if let Some(e) = item.as_view().finger_down(actions) {
                if !e.device.is_primary_hit() && self.rows.get(index).is_some_and(|r| !r.id.is_empty()) {
                    out = Some(MessageAction::Context(index, e.abs));
                    continue;
                }
            }
            let author_paths: [&[LiveId]; 2] = [ids!(line.avatar), ids!(line.content.head.who)];
            for path in author_paths {
                if let Some(e) = item.view(cx, path).finger_up(actions).filter(|e| !e.cancelled && e.was_tap()) {
                    if self.rows.get(index).is_some_and(|r| !r.author_pk.is_empty()) {
                        out = Some(MessageAction::Author(index, e.abs));
                    }
                }
            }
            let clicked = |path: &[LiveId]| item.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled);
            if clicked(ids!(toolbar.reply_btn)) {
                out = Some(MessageAction::Reply(index));
            } else if clicked(ids!(toolbar.edit_btn)) {
                out = Some(MessageAction::Edit(index));
            } else if clicked(ids!(toolbar.pin_btn)) {
                out = Some(MessageAction::Pin(index));
            } else if clicked(ids!(line.content.reply)) {
                if let Some(parent) = self.rows.get(index).and_then(|r| r.reply_to.clone()) {
                    self.jump_to(cx, &parent);
                }
            }
        }
        out
    }

    /// After sending, follow the newest message again.
    pub fn follow_end(&mut self, cx: &mut Cx) {
        if let Some(mut list) = self.view.portal_list(cx, ids!(list)).borrow_mut() {
            list.set_tail_range(true);
        }
        self.view.redraw(cx);
    }
}

impl Widget for MessageList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        let started = std::time::Instant::now();
        let mut drawn = 0u32;
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            let count = self.rows.len();
            list.set_item_range(cx, 0, count);
            // Tail-follow alone settles a few rows short when the last rows
            // wrap (it works from estimated heights), so once a frame has
            // measured them, scroll to the real end; auto_tail follows on.
            match self.opened_frames {
                0 => list.set_tail_range(true),
                1 => list.smooth_scroll_to_end(cx, 1.0e6, None),
                _ => {}
            }
            self.opened_frames = self.opened_frames.saturating_add(1);
            let flash_alpha = |index: usize| -> f32 {
                match self.flash {
                    Some((i, at)) if i == index => (1.0 - at.elapsed().as_secs_f32() / FLASH_SECS).max(0.0),
                    _ => 0.0,
                }
            };
            while let Some(index) = list.next_visible_item(cx) {
                let Some(msg) = self.rows.get(index) else { continue };
                drawn += 1;
                let hovered = self.hovered == Some(index);
                let flash = flash_alpha(index);
                let body = msg.body.as_deref().unwrap_or("🔒 Encrypted — you don't have this channel's key yet");

                if msg.system {
                    let row = list.item(cx, index, id!(MsgSystem));
                    row.label(cx, ids!(body)).set_text(cx, body);
                    row.label(cx, ids!(time)).set_text(cx, &clock(msg.at));
                    row.draw_all(cx, &mut Scope::empty());
                    continue;
                }
                let item = list.item(cx, index, if msg.grouped { id!(MsgGrouped) } else { id!(MsgFull) });
                let toolbar = item.view(cx, ids!(toolbar));
                toolbar.set_visible(cx, hovered && !msg.id.is_empty());
                item.view(cx, ids!(toolbar.edit_btn)).set_visible(cx, msg.own);
                item.view(cx, ids!(toolbar.pin_btn)).set_visible(cx, self.can_pin);
                let mut row_bg = item.clone();
                script_apply_eval!(cx, row_bg, {draw_bg +: {flash: #(flash)}});

                if msg.grouped {
                    item.label(cx, ids!(line.body)).set_text(cx, body);
                    item.draw_all(cx, &mut Scope::empty());
                    continue;
                }

                let row = item.view(cx, ids!(line));
                let mut avatar = row.widget(cx, ids!(avatar));
                let fill = rgba(msg.avatar, 1.0);
                script_apply_eval!(cx, avatar, {draw_bg +: {color: #(fill)}});
                row.label(cx, ids!(avatar.initial)).set_text(cx, &msg.initial);
                let mut name = row.widget(cx, ids!(content.head.name));
                let role = rgba(msg.color, 1.0);
                script_apply_eval!(cx, name, {draw_text +: {color: #(role)}});
                name.set_text(cx, &msg.author);
                let edited = if msg.edited { "  (edited)" } else { "" };
                let pinned = if msg.pinned { "  📌" } else { "" };
                row.label(cx, ids!(content.head.time)).set_text(cx, &format!("{}{edited}{pinned}", clock(msg.at)));
                row.view(cx, ids!(content.reply)).set_visible(cx, msg.reply.is_some());
                row.label(cx, ids!(content.reply.text)).set_text(cx, msg.reply.as_deref().unwrap_or(""));
                row.label(cx, ids!(content.body)).set_text(cx, body);
                item.draw_all(cx, &mut Scope::empty());
            }
        }
        self.perf.record(started.elapsed(), drawn);
        let flashing = self.flash.is_some_and(|(_, at)| at.elapsed().as_secs_f32() < FLASH_SECS);
        if !flashing && self.flash.is_some() {
            self.flash = None;
        }
        if self.opened_frames <= 2 || flashing {
            // Not inside the loop: the list is borrowed there.
            self.view.redraw(cx);
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}
