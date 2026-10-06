//! The shell's live lists: server rail, channel sidebar and member list.
//! Each is a `PortalList` over rows the backend sends, so they redraw only
//! what's visible and stay cheap however big a server gets.

use makepad_widgets::*;

use crate::backend::{MemberRow, ServerItem, SidebarRow};

pub(crate) fn rgba(hex: u32, alpha: f32) -> Vec4 {
    let [r, g, b, _] = crate::theme::Rgb(hex).vec4(1.0);
    vec4(r, g, b, alpha)
}

/// Re-records every live row of `list`. Rows with `new_batch` keep a cached
/// draw that doesn't notice text changes, so after the data changes (an
/// edit, a renamed member) they'd keep showing the old text.
pub(crate) fn redraw_items(cx: &mut Cx, list: &PortalListRef) {
    if let Some(list) = list.borrow() {
        for item in list.items().values() {
            item.widget.redraw(cx);
        }
    }
    list.redraw(cx);
}

/// A clicked row, if `item` was clicked in `actions`.
fn clicked(item: &WidgetRef, actions: &Actions) -> bool {
    item.as_view().finger_up(actions).is_some_and(|e| !e.cancelled)
}

// ─── Rail ────────────────────────────────────────────────────────────────

#[derive(Script, ScriptHook, Widget)]
pub struct RailList {
    #[deref]
    view: View,
    #[rust]
    pub servers: Vec<ServerItem>,
    #[rust]
    pub selected: Option<String>,
}

impl RailList {
    /// The gid clicked in `actions`, if any.
    pub fn clicked(&self, cx: &mut Cx, actions: &Actions) -> Option<String> {
        let list = self.view.portal_list(cx, ids!(list));
        list.items_with_actions(actions)
            .into_iter()
            .find(|(_, item)| clicked(item, actions))
            .and_then(|(i, _)| self.servers.get(i).map(|s| s.gid.clone()))
    }
}

impl Widget for RailList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.servers.len());
            while let Some(i) = list.next_visible_item(cx) {
                let Some(s) = self.servers.get(i) else { continue };
                let active = self.selected.as_deref() == Some(s.gid.as_str());
                let row = list.item(cx, i, if active { id!(Active) } else { id!(Idle) });
                row.label(cx, ids!(icon.initials)).set_text(cx, &s.initials);
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

// ─── Channel sidebar ─────────────────────────────────────────────────────

#[derive(Script, ScriptHook, Widget)]
pub struct ChannelList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<SidebarRow>,
    #[rust]
    pub selected: Option<String>,
}

impl ChannelList {
    pub fn clicked(&self, cx: &mut Cx, actions: &Actions) -> Option<String> {
        let list = self.view.portal_list(cx, ids!(list));
        list.items_with_actions(actions)
            .into_iter()
            .find(|(_, item)| clicked(item, actions))
            .and_then(|(i, _)| match self.rows.get(i) {
                Some(SidebarRow::Channel { id, voice: false, .. }) => Some(id.clone()),
                _ => None,
            })
    }
}

impl Widget for ChannelList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.rows.len());
            while let Some(i) = list.next_visible_item(cx) {
                let Some(r) = self.rows.get(i) else { continue };
                match r {
                    SidebarRow::Category(name) => {
                        let row = list.item(cx, i, id!(Category));
                        row.label(cx, ids!(label)).set_text(cx, name);
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    SidebarRow::Channel { id, name, voice, encrypted } => {
                        let active = self.selected.as_deref() == Some(id.as_str());
                        let row = list.item(cx, i, if active { id!(ActiveChannel) } else { id!(Channel) });
                        let glyph = if *voice { "🔊" } else if *encrypted { "🔒" } else { "#" };
                        row.label(cx, ids!(item.hash)).set_text(cx, glyph);
                        row.label(cx, ids!(item.name)).set_text(cx, name);
                        row.draw_all(cx, &mut Scope::empty());
                    }
                }
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

// ─── Member list ─────────────────────────────────────────────────────────

#[derive(Script, ScriptHook, Widget)]
pub struct MemberList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<MemberRow>,
}

impl Widget for MemberList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.rows.len());
            while let Some(i) = list.next_visible_item(cx) {
                let Some(r) = self.rows.get(i) else { continue };
                match r {
                    MemberRow::Header { text, color } => {
                        let mut row = list.item(cx, i, id!(Header));
                        let c = rgba(*color, 1.0);
                        script_apply_eval!(cx, row, {draw_text +: {color: #(c)}});
                        row.set_text(cx, text);
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    MemberRow::Member { name, initial, color, avatar } => {
                        let row = list.item(cx, i, id!(Member));
                        let mut face = row.widget(cx, ids!(face.avatar));
                        let a = rgba(*avatar, 1.0);
                        script_apply_eval!(cx, face, {draw_bg +: {color: #(a)}});
                        row.label(cx, ids!(face.avatar.initial)).set_text(cx, initial);
                        let mut n = row.widget(cx, ids!(name));
                        let c = rgba(*color, 1.0);
                        script_apply_eval!(cx, n, {draw_text +: {color: #(c)}});
                        n.set_text(cx, name);
                        row.draw_all(cx, &mut Scope::empty());
                    }
                }
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

// ─── Pinned messages panel ───────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub struct PinRow {
    pub id: String,
    pub author: String,
    pub body: String,
}

#[derive(Script, ScriptHook, Widget)]
pub struct PinsList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<PinRow>,
}

impl PinsList {
    /// The event id of the pin clicked in `actions`, if any.
    pub fn clicked(&self, cx: &mut Cx, actions: &Actions) -> Option<String> {
        let list = self.view.portal_list(cx, ids!(list));
        list.items_with_actions(actions)
            .into_iter()
            .find(|(_, item)| clicked(item, actions))
            .and_then(|(i, _)| self.rows.get(i).map(|r| r.id.clone()))
    }
}

impl Widget for PinsList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            let count = self.rows.len().max(1);
            list.set_item_range(cx, 0, count);
            while let Some(i) = list.next_visible_item(cx) {
                match self.rows.get(i) {
                    Some(r) => {
                        let row = list.item(cx, i, id!(Pin));
                        row.label(cx, ids!(author)).set_text(cx, &r.author);
                        row.label(cx, ids!(body)).set_text(cx, &r.body);
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    None if i == 0 => {
                        let row = list.item(cx, i, id!(Empty));
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    None => {}
                }
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}
