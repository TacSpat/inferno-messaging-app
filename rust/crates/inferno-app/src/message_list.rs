//! The message list: a `PortalList` that only builds the rows on screen, so
//! 10,000 messages cost the same per frame as 20.

use makepad_widgets::*;

use crate::demo::{self, DemoMessage, AUTHORS};
use crate::theme;

const HISTORY: usize = 10_000;

#[derive(Script, ScriptHook, Widget)]
pub struct MessageList {
    #[deref]
    view: View,
    #[rust]
    messages: Vec<DemoMessage>,
    /// Frames drawn since opening; the jump to the newest message waits one
    /// frame so real row heights replace estimates first.
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

fn rgba(hex: u32) -> Vec4 {
    let [r, g, b, a] = theme::Rgb(hex).vec4(1.0);
    vec4(r, g, b, a)
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

impl MessageList {
    /// Appends our own message and keeps the view pinned to the bottom.
    pub fn push_own(&mut self, cx: &mut Cx, text: &str) {
        let at = self.messages.last().map_or(0, |m| m.at + 30);
        self.messages.push(DemoMessage {
            author: 0,
            at,
            body: text.to_owned(),
            system: false,
            reply_to: None,
            edited: false,
        });
        // Sending always brings you back to the newest message.
        if let Some(mut list) = self.view.portal_list(cx, ids!(list)).borrow_mut() {
            list.set_tail_range(true);
        }
        self.view.redraw(cx);
    }
}

impl Widget for MessageList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        if self.messages.is_empty() {
            self.messages = demo::history(HISTORY);
        }
        let started = std::time::Instant::now();
        let mut rows = 0u32;
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            let count = self.messages.len();
            list.set_item_range(cx, 0, count);
            // Chat opens at the newest message. Tail-follow alone settles a few
            // rows short when the last rows wrap (it works from estimated
            // heights), so once a frame has measured them, scroll to the
            // real end; auto_tail follows from there.
            match self.opened_frames {
                0 => list.set_tail_range(true),
                1 => list.smooth_scroll_to_end(cx, 1.0e6, None),
                _ => {}
            }
            self.opened_frames = self.opened_frames.saturating_add(1);
            while let Some(index) = list.next_visible_item(cx) {
                let Some(msg) = self.messages.get(index) else { continue };
                rows += 1;
                let prev = index.checked_sub(1).and_then(|i| self.messages.get(i));
                let author = &AUTHORS[msg.author];

                if msg.system {
                    let row = list.item(cx, index, id!(MsgSystem));
                    row.label(cx, ids!(body)).set_text(cx, &msg.body);
                    row.label(cx, ids!(time)).set_text(cx, &clock(msg.at));
                    row.draw_all(cx, &mut Scope::empty());
                    continue;
                }

                if demo::grouped(prev, msg) {
                    let row = list.item(cx, index, id!(MsgGrouped));
                    row.label(cx, ids!(body)).set_text(cx, &msg.body);
                    row.draw_all(cx, &mut Scope::empty());
                    continue;
                }

                let row = list.item(cx, index, id!(MsgFull));
                let mut avatar = row.widget(cx, ids!(avatar));
                let fill = rgba(author.avatar_color);
                script_apply_eval!(cx, avatar, {draw_bg +: {color: #(fill)}});
                row.label(cx, ids!(avatar.initial)).set_text(cx, &author.name[..1].to_uppercase());

                let mut name = row.widget(cx, ids!(content.head.name));
                let role = rgba(author.role_color);
                script_apply_eval!(cx, name, {draw_text +: {color: #(role)}});
                name.set_text(cx, author.name);
                let edited = if msg.edited { "  (edited)" } else { "" };
                row.label(cx, ids!(content.head.time)).set_text(cx, &format!("10/05/2026 {}{edited}", clock(msg.at)));

                // Reply preview: parent author and body cut at 60 characters.
                let reply = msg.reply_to.and_then(|i| self.messages.get(i)).map(|p| {
                    let cut: String = p.body.chars().take(60).collect();
                    format!("↳ {}  {}", AUTHORS[p.author].name, cut)
                });
                let reply_label = row.label(cx, ids!(content.reply));
                reply_label.set_visible(cx, reply.is_some());
                reply_label.set_text(cx, reply.as_deref().unwrap_or(""));

                row.label(cx, ids!(content.body)).set_text(cx, &msg.body);
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        self.perf.record(started.elapsed(), rows);
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
