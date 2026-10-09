//! Right-click context menus, presented as Rails does
//! (`notification_badge_controller.js#renderContextMenu`): a gray-900 box
//! with a gray-700 border, radius 8, padding 6, at least 200px wide, opened
//! at the pointer and kept inside the window; danger items are red.
//!
//! The menu is a fixed set of slots in the DSL; [`Menu`] fills them.

/// What a menu item does when picked.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    CreateChannel { category: Option<String> },
    CreateCategory,
    MarkRead(String),
    EditChannel(String),
    DeleteChannel(String),
    EditCategory(String),
    DeleteCategory(String),
    Copy(String),
    Reply(usize),
    Edit(usize),
    Pin(usize),
    DeleteMessage(usize),
    Mention(String),
    /// Opens the roles submenu for a member.
    RolesFor(String),
    ToggleRole { member: String, role: String },
    /// Opens the timeout submenu for a member.
    TimeoutFor(String),
    Timeout { member: String, secs: i64 },
    /// Members page: time out everyone selected.
    BatchTimeout(i64),
    Kick(String),
    Ban(String),
    /// Opens (or starts) a DM with this pubkey.
    Message(String),
    AddFriend(String),
    AcceptFriend(String),
    DeclineFriend(String),
    /// Remove Friend, or cancel an outgoing request.
    RemoveFriend(String),
    Block(String),
    MarkDmRead(String),
    CloseDm(String),
    GifFavorite(inferno_core::gifs::Gif),
    GifCollection { id: String, gif: inferno_core::gifs::Gif },
    DeleteGifCollection(String),
    /// Opens a link in the browser.
    OpenUrl(String),
    /// Downloads a picture, video, sound or file (the save dialog first).
    SaveMedia { url: String, name: String },
    /// The picture itself on the clipboard.
    CopyImage(String),
    /// Voice (Rails' voice context menu).
    VoiceProfile(String),
    VoiceSelfMute,
    VoiceSelfDeafen,
    Moderate { target: String, action: inferno_core::session::VoiceModeration },
    MoveFor(String),
    VoiceDisconnect(String),
    Showcase { target: String, on: bool },
    /// Mute someone for ourselves only (not a server mute).
    LocalMute { target: String, on: bool },
    /// Returns to the menu this submenu came from.
    Back,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    Action { action: Action, label: String, danger: bool },
    /// Rails' toggle switch: flipping it keeps the menu open.
    Toggle { action: Action, label: String, on: bool },
    /// Opens beside the menu when hovered (Rails' flyouts: Move to, Roles).
    Sub { label: String, items: Vec<Item> },
    /// Rails' "User Volume": a 0..200% slider for one person (pubkey hex).
    Volume { pubkey: String, percent: u32 },
    Separator,
}

impl Item {
    pub fn new(label: impl Into<String>, action: Action) -> Self {
        Item::Action { action, label: label.into(), danger: false }
    }
    pub fn danger(label: impl Into<String>, action: Action) -> Self {
        Item::Action { action, label: label.into(), danger: true }
    }
    pub fn toggle(label: impl Into<String>, on: bool, action: Action) -> Self {
        Item::Toggle { action, label: label.into(), on }
    }
    pub fn sub(label: impl Into<String>, items: Vec<Item>) -> Self {
        Item::Sub { label: label.into(), items }
    }
    pub fn volume(pubkey: impl Into<String>, percent: u32) -> Self {
        Item::Volume { pubkey: pubkey.into(), percent }
    }
}

/// What a slot does.
#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    Action(Action),
    Toggle(Action, bool),
    Sub(Vec<Item>),
    Volume(String, u32),
}

/// One drawn row: an item, optionally preceded by a separator.
#[derive(Debug, Clone, PartialEq)]
pub struct Slot {
    pub sep: bool,
    pub label: String,
    pub danger: bool,
    pub kind: Kind,
}

/// The action a toggle sends after flipping: one that carries the state
/// it sets gets the other state.
pub fn flipped(action: &Action) -> Action {
    use inferno_core::session::VoiceModeration as M;
    match action {
        Action::Moderate { target, action: M::ServerMute(on) } => Action::Moderate { target: target.clone(), action: M::ServerMute(!on) },
        Action::Moderate { target, action: M::ServerDeafen(on) } => Action::Moderate { target: target.clone(), action: M::ServerDeafen(!on) },
        Action::Showcase { target, on } => Action::Showcase { target: target.clone(), on: !on },
        Action::LocalMute { target, on } => Action::LocalMute { target: target.clone(), on: !on },
        other => other.clone(),
    }
}

/// Slots available in the DSL (`ctx_menu.s0` … `s13`, `ctx_sub.u0` …).
pub const SLOTS: usize = 14;
/// Approximate heights for keeping the menu on screen.
pub const ITEM_H: f64 = 30.0;
pub const SEP_H: f64 = 9.0;
pub const WIDTH: f64 = 200.0;
/// Rails clamps menus 24px from the viewport edges.
pub const EDGE: f64 = 24.0;

/// Laid out for the slots: each slot is an item, optionally preceded by a
/// separator (separators attach to the next item).
pub fn layout(items: &[Item]) -> Vec<Slot> {
    let mut out = Vec::new();
    let mut sep = false;
    for item in items {
        let (label, danger, kind) = match item {
            Item::Separator => {
                sep = !out.is_empty();
                continue;
            }
            Item::Action { action, label, danger } => (label.clone(), *danger, Kind::Action(action.clone())),
            Item::Toggle { action, label, on } => (label.clone(), false, Kind::Toggle(action.clone(), *on)),
            Item::Sub { label, items } => (label.clone(), false, Kind::Sub(items.clone())),
            Item::Volume { pubkey, percent } => ("User Volume".to_owned(), false, Kind::Volume(pubkey.clone(), *percent)),
        };
        out.push(Slot { sep, label, danger, kind });
        sep = false;
    }
    out.truncate(SLOTS);
    out
}

pub fn height(slots: &[Slot]) -> f64 {
    12.0 + slots.iter().map(|s| ITEM_H + if s.sep { SEP_H } else { 0.0 }).sum::<f64>()
}

/// Where a flyout for the row at `row_y` opens: right of the menu, or left
/// of it when the window has no room (Rails' flyout flips the same way).
pub fn flyout(menu: (f64, f64, f64), row_y: f64, size: (f64, f64), window: (f64, f64)) -> (f64, f64) {
    let (mx, _my, mw) = menu;
    let right = mx + mw - 2.0;
    let x = if right + size.0 + EDGE <= window.0 { right } else { (mx - size.0 + 2.0).max(EDGE.min(mx)) };
    let y = (row_y - 6.0).min(window.1 - size.1 - EDGE).max(EDGE.min(row_y));
    (x, y)
}

/// Top-left for a menu opened at `at`, kept `EDGE` inside `window`.
pub fn place(at: (f64, f64), size: (f64, f64), window: (f64, f64)) -> (f64, f64) {
    let x = at.0.min(window.0 - size.0 - EDGE).max(EDGE.min(at.0));
    let y = at.1.min(window.1 - size.1 - EDGE).max(EDGE.min(at.1));
    (x, y)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn separators_attach_to_the_next_item_and_never_lead() {
        let items = [
            Item::Separator,
            Item::new("A", Action::CreateCategory),
            Item::Separator,
            Item::Separator,
            Item::new("B", Action::Back),
            Item::Separator,
        ];
        let l = layout(&items);
        assert_eq!(l.len(), 2);
        assert!(!l[0].sep, "no separator before the first item");
        assert!(l[1].sep);
    }

    #[test]
    fn flyouts_flip_when_there_is_no_room() {
        assert_eq!(flyout((100.0, 50.0, 200.0), 120.0, (200.0, 100.0), (1400.0, 860.0)), (298.0, 114.0));
        let (x, _) = flyout((1100.0, 50.0, 200.0), 120.0, (200.0, 100.0), (1400.0, 860.0));
        assert_eq!(x, 902.0, "left of the menu");
    }

    #[test]
    fn menus_stay_inside_the_window() {
        assert_eq!(place((100.0, 100.0), (200.0, 150.0), (1400.0, 860.0)), (100.0, 100.0));
        assert_eq!(place((1350.0, 800.0), (200.0, 150.0), (1400.0, 860.0)), (1176.0, 686.0));
    }
}
