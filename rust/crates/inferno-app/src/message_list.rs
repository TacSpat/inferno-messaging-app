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
}

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
        self.view.redraw(cx);
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
            while let Some(index) = list.next_visible_item(cx) {
                let Some(msg) = self.rows.get(index) else { continue };
                drawn += 1;
                let body = msg.body.as_deref().unwrap_or("🔒 Encrypted — you don't have this channel's key yet");

                if msg.system {
                    let row = list.item(cx, index, id!(MsgSystem));
                    row.label(cx, ids!(body)).set_text(cx, body);
                    row.label(cx, ids!(time)).set_text(cx, &clock(msg.at));
                    row.draw_all(cx, &mut Scope::empty());
                    continue;
                }
                if msg.grouped {
                    let row = list.item(cx, index, id!(MsgGrouped));
                    row.label(cx, ids!(body)).set_text(cx, body);
                    row.draw_all(cx, &mut Scope::empty());
                    continue;
                }

                let row = list.item(cx, index, id!(MsgFull));
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
                let reply = row.label(cx, ids!(content.reply));
                reply.set_visible(cx, msg.reply.is_some());
                reply.set_text(cx, msg.reply.as_deref().unwrap_or(""));
                row.label(cx, ids!(content.body)).set_text(cx, body);
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        self.perf.record(started.elapsed(), drawn);
        if self.opened_frames <= 2 {
            // Not inside the loop: the list is borrowed there.
            self.view.redraw(cx);
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}
