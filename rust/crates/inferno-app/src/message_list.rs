//! The message list: a `PortalList` that only builds the rows on screen, so
//! 10,000 messages cost the same per frame as 20. Rows come from the backend
//! already resolved; `INFERNO_DEMO=1` swaps in the 10,000-message synthetic
//! history for performance checks.

use std::collections::HashMap;

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
    /// DMs have no replies (Rails' DM payloads carry none).
    #[rust]
    pub no_reply: bool,
    /// Lowercase `@word` → `mention:` target, for this timeline.
    #[rust]
    pub mentions: HashMap<String, String>,
    /// Row flashing after a jump, and when the flash started.
    #[rust]
    flash: Option<(usize, std::time::Instant)>,
    /// A right-click waiting for the app: row, where, what it landed on.
    #[rust]
    context: Option<(usize, DVec2, Option<crate::message_text::MediaTarget>)>,
}

/// What a click in the list asks the app to do.
#[derive(Debug, Clone, PartialEq)]
pub enum MessageAction {
    Reply(usize),
    Edit(usize),
    Pin(usize),
    /// Right-click on a row at a window position, and what it landed on
    /// (a link, picture, video...) for that thing's own menu items.
    Context(usize, DVec2, Option<crate::message_text::MediaTarget>),
    /// Click on the author's avatar or name, at a window position.
    Author(usize, DVec2),
    /// Join (or open, once joined) the server of the row's invite card.
    Invite(usize),
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

use crate::time_fmt::clock;

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
                picture: None,
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
                invite: None,
                emojis: Default::default(),
                files: Vec::new(),
                spoiler: false,
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

    /// The row under `abs` and what in it is there.
    fn context_at(&mut self, cx: &mut Cx, abs: DVec2) -> Option<(usize, DVec2, Option<crate::message_text::MediaTarget>)> {
        let list = self.view.portal_list(cx, ids!(list));
        let list = list.borrow()?;
        let (index, item) = list
            .items()
            .iter()
            .map(|(i, item)| (*i, item.widget.clone()))
            .find(|(_, w)| w.area().is_valid(cx) && w.area().clipped_rect(cx).contains(abs))?;
        drop(list);
        if self.rows.get(index).is_none_or(|r| r.id.is_empty()) {
            return None;
        }
        let target = item
            .widget(cx, ids!(line.content.body))
            .borrow_mut::<crate::message_text::MessageText>()
            .and_then(|mut body| body.target_at(cx, abs));
        Some((index, abs, target))
    }

    /// Handles hover and clicks inside the rows.
    pub fn handle_list_actions(&mut self, cx: &mut Cx, actions: &Actions) -> Option<MessageAction> {
        if let Some((index, at, target)) = self.context.take() {
            return Some(MessageAction::Context(index, at, target));
        }
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
            let author_paths: [&[LiveId]; 2] = [ids!(line.avatar), ids!(line.content.head.who)];
            for path in author_paths {
                if let Some(e) = item.view(cx, path).finger_up(actions).filter(|e| !e.cancelled && e.was_tap()) {
                    if self.rows.get(index).is_some_and(|r| !r.author_pk.is_empty()) {
                        out = Some(MessageAction::Author(index, e.abs));
                    }
                }
            }
            let clicked = |path: &[LiveId]| item.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled);
            if clicked(ids!(line.content.invite.join)) {
                out = Some(MessageAction::Invite(index));
            } else if clicked(ids!(toolbar.reply_btn)) {
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

/// Fills a row's invite card (Rails' embed states, Flutter's Join).
fn fill_invite(cx: &mut Cx, card: &WidgetRef, invite: Option<&crate::backend::InviteCard>) {
    use crate::backend::InviteCard;
    use inferno_core::session::InviteStatus;
    let Some(invite) = invite else {
        card.set_visible(cx, false);
        return;
    };
    card.set_visible(cx, true);
    let (name, picture, kicker, detail, button, live) = match invite {
        InviteCard::Loading => ("Resolving invite…".to_owned(), None, "", String::new(), None, true),
        InviteCard::Unavailable => ("Unknown server".to_owned(), None, "", "Invite Unavailable".to_owned(), None, false),
        InviteCard::Ready(p) => {
            let reason = match p.status {
                InviteStatus::Valid => None,
                InviteStatus::Expired => Some("Invite Expired"),
                InviteStatus::Revoked => Some("Invite No Longer Valid"),
                InviteStatus::MaxedOut => Some("Invite Reached Max Uses"),
                InviteStatus::Banned => Some("You are banned from this server"),
            };
            let mut bits = Vec::new();
            if let Some(n) = p.members {
                bits.push(format!("{n} Member{}", if n == 1 { "" } else { "s" }));
            }
            if p.age_restricted {
                bits.push("18+".into());
            }
            // Rails: a dead invite shows its reason, even to members.
            let kicker = "You've been invited to join a server";
            match reason {
                Some(r) => (p.name.clone(), p.picture.clone(), "", r.to_owned(), None, false),
                None if p.joined => (p.name.clone(), p.picture.clone(), kicker, bits.join(" · "), Some("Joined"), true),
                None => (p.name.clone(), p.picture.clone(), kicker, bits.join(" · "), Some("Join"), true),
            }
        }
    };
    let initial = name.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_else(|| "?".into());
    card.label(cx, ids!(icon.initial)).set_text(cx, if matches!(invite, InviteCard::Ready(_)) { &initial } else { "?" });
    crate::images::show(cx, &card.image(cx, ids!(icon.pic)), picture.as_deref());
    card.label(cx, ids!(kicker)).set_text(cx, kicker);
    card.widget(cx, ids!(kicker)).set_visible(cx, !kicker.is_empty());
    let mut name_w = card.widget(cx, ids!(name));
    let fg = if live { rgba(0xffffff, 1.0) } else { crate::theme::tok("gray_400", 1.0) };
    script_apply_eval!(cx, name_w, {draw_text +: {color: #(fg)}});
    name_w.set_text(cx, &name);
    card.label(cx, ids!(detail)).set_text(cx, &detail);
    card.widget(cx, ids!(detail)).set_visible(cx, !detail.is_empty());
    let mut j = card.widget(cx, ids!(join));
    j.set_visible(cx, button.is_some());
    if let Some(text) = button {
        card.label(cx, ids!(join.label)).set_text(cx, text);
        let bg = if text == "Joined" { crate::theme::tok("gray_700", 1.0) } else { crate::theme::tok("confirm", 1.0) };
        script_apply_eval!(cx, j, {draw_bg +: {color: #(bg)}});
    }
    let mut c = card.clone();
    let alpha = if live { 0.6 } else { 0.4 };
    let bg = crate::theme::tok("gray_800", alpha);
    script_apply_eval!(cx, c, {draw_bg +: {color: #(bg)}});
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
            crate::inline_video::begin_pass();
            while let Some(index) = list.next_visible_item(cx) {
                let Some(msg) = self.rows.get(index) else { continue };
                drawn += 1;
                crate::inline_video::see_row(&msg.id);
                crate::inline_video::set_row(&msg.id);
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
                item.view(cx, ids!(toolbar.reply_btn)).set_visible(cx, !self.no_reply);
                let mut row_bg = item.clone();
                script_apply_eval!(cx, row_bg, {draw_bg +: {flash: #(flash)}});

                // Markdown re-lays-out on every set, so only set what changed.
                // The card stands in for its link, as in Rails.
                let body = match &msg.invite {
                    Some((link, _)) => body.replacen(link.as_str(), "", 1),
                    None => body.to_owned(),
                };
                let mentions = &self.mentions;
                let resolve = |word: &str| mentions.get(&word.to_lowercase()).cloned();
                let emojis = &msg.emojis;
                let emoji = |name: &str| emojis.get(name).cloned();
                let files = |url: &str| {
                    msg.files.iter().find(|f| f.url == url).cloned().or_else(|| {
                        crate::message_format::is_blob(url)
                            .then(|| crate::media_probe::lookup(url))
                            .flatten()
                    })
                };
                let md = crate::message_format::to_markdown_full(body.trim(), &resolve, &emoji, &files, msg.spoiler);
                // Rails' emoji-only messages: big Unicode emoji too.
                let big = crate::message_format::emoji_only(body.trim(), &emoji);
                let mut w = item.widget(cx, ids!(line.content.body));
                let size = if big { 30.0 } else { 10.5 };
                script_apply_eval!(cx, w, {font_size: #(size)});
                if w.text() != md {
                    w.set_text(cx, &md);
                }
                w.set_visible(cx, !md.trim().is_empty());
                let card = item.widget(cx, ids!(line.content.invite));
                fill_invite(cx, &card, msg.invite.as_ref().map(|(_, c)| c));
                if msg.grouped {
                    item.draw_all(cx, &mut Scope::empty());
                    continue;
                }

                let row = item.view(cx, ids!(line));
                let mut avatar = row.widget(cx, ids!(avatar));
                let fill = rgba(msg.avatar, 1.0);
                script_apply_eval!(cx, avatar, {draw_bg +: {color: #(fill)}});
                row.label(cx, ids!(avatar.initial)).set_text(cx, &msg.initial);
                let img = row.image(cx, ids!(avatar.pic));
                crate::images::show(cx, &img, msg.picture.as_deref());
                let mut name = row.widget(cx, ids!(content.head.name));
                let role = rgba(msg.color, 1.0);
                script_apply_eval!(cx, name, {draw_text +: {color: #(role)}});
                name.set_text(cx, &msg.author);
                let edited = if msg.edited { "  (edited)" } else { "" };
                let pinned = if msg.pinned { "  📌" } else { "" };
                row.label(cx, ids!(content.head.time)).set_text(cx, &format!("{}{edited}{pinned}", clock(msg.at)));
                row.view(cx, ids!(content.reply)).set_visible(cx, msg.reply.is_some());
                row.label(cx, ids!(content.reply.text)).set_text(cx, msg.reply.as_deref().unwrap_or(""));
                item.draw_all(cx, &mut Scope::empty());
            }
            crate::inline_video::set_row("");
            crate::inline_video::end_pass();
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
        // Right-clicks from the raw press: pictures, cards and the video
        // player take presses for themselves, and the row would never hear.
        if let Event::MouseDown(m) = event {
            if !m.button.is_primary() && self.view.area().clipped_rect(cx).contains(m.abs) {
                self.context = self.context_at(cx, m.abs);
                if self.context.is_some() {
                    cx.widget_action(self.widget_uid(), MessageAction::Context(0, m.abs, None));
                }
            }
        }
        self.view.handle_event(cx, event, scope);
    }
}
