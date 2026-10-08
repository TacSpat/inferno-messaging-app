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
    /// Returns to the menu this submenu came from.
    Back,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Item {
    Action { action: Action, label: String, danger: bool },
    Separator,
}

impl Item {
    pub fn new(label: impl Into<String>, action: Action) -> Self {
        Item::Action { action, label: label.into(), danger: false }
    }
    pub fn danger(label: impl Into<String>, action: Action) -> Self {
        Item::Action { action, label: label.into(), danger: true }
    }
}

/// Slots available in the DSL (`ctx_menu.s0` … `s13`).
pub const SLOTS: usize = 14;
/// Approximate heights for keeping the menu on screen.
pub const ITEM_H: f64 = 30.0;
pub const SEP_H: f64 = 9.0;
pub const WIDTH: f64 = 200.0;
/// Rails clamps menus 24px from the viewport edges.
pub const EDGE: f64 = 24.0;

/// Laid out for the slots: each slot is an item, optionally preceded by a
/// separator (separators attach to the next item).
pub fn layout(items: &[Item]) -> Vec<(bool, Action, String, bool)> {
    let mut out = Vec::new();
    let mut sep = false;
    for item in items {
        match item {
            Item::Separator => sep = !out.is_empty(),
            Item::Action { action, label, danger } => {
                out.push((sep, action.clone(), label.clone(), *danger));
                sep = false;
            }
        }
    }
    out.truncate(SLOTS);
    out
}

pub fn height(slots: &[(bool, Action, String, bool)]) -> f64 {
    12.0 + slots.iter().map(|s| ITEM_H + if s.0 { SEP_H } else { 0.0 }).sum::<f64>()
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
        assert!(!l[0].0, "no separator before the first item");
        assert!(l[1].0);
    }

    #[test]
    fn menus_stay_inside_the_window() {
        assert_eq!(place((100.0, 100.0), (200.0, 150.0), (1400.0, 860.0)), (100.0, 100.0));
        assert_eq!(place((1350.0, 800.0), (200.0, 150.0), (1400.0, 860.0)), (1176.0, 686.0));
    }
}
