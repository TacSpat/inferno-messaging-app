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

#[derive(Debug, Clone, PartialEq)]
pub enum ChannelListAction {
    Select(String),
    /// The category's hover "+": create a channel in it.
    CreateIn(String),
    /// Right-click on a row (`None` = empty sidebar space) at window `at`.
    Context { row: Option<SidebarRow>, at: (f64, f64) },
    Move { id: String, category: Option<String>, index: usize },
}

/// A press on a channel row that may turn into a drag.
#[derive(Debug, Clone)]
struct Drag {
    row: usize,
    start_y: f64,
    moving: bool,
    /// Insert position among the sidebar rows, while moving.
    slot: Option<usize>,
}

/// Pointer travel before a press on a row becomes a drag.
const DRAG_THRESHOLD: f64 = 5.0;

#[derive(Script, ScriptHook, Widget)]
pub struct ChannelList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<SidebarRow>,
    #[rust]
    pub selected: Option<String>,
    /// manage_channels: gears and drag-to-reorder.
    #[rust]
    pub can_manage: bool,
    #[rust]
    hovered: Option<usize>,
    #[rust]
    drag: Option<Drag>,
}

impl ChannelList {
    /// Where among the rows the pointer at `y` would drop, and the y of the
    /// drop line, from the rows currently drawn.
    fn slot_at(&self, cx: &Cx, y: f64) -> Option<(usize, f64)> {
        let list = self.view.portal_list(cx, ids!(list));
        let list_ref = list.borrow()?;
        let mut rects: Vec<(usize, Rect)> = list_ref
            .items()
            .iter()
            .map(|(i, item)| (*i, item.widget.area().rect(cx)))
            .filter(|(_, r)| r.size.y > 0.0)
            .collect();
        rects.sort_by_key(|(i, _)| *i);
        let (first, last) = (rects.first()?, rects.last()?);
        for (i, r) in &rects {
            if y < r.pos.y + r.size.y / 2.0 {
                return Some((*i, r.pos.y));
            }
        }
        Some((last.0 + 1, last.1.pos.y + last.1.size.y)).filter(|_| first.0 <= last.0)
    }

    pub fn contains(&self, cx: &Cx, abs: DVec2) -> bool {
        self.view.area().rect(cx).contains(abs)
    }

    /// Whether `abs` is over a drawn row.
    pub fn row_at(&self, cx: &Cx, abs: DVec2) -> bool {
        let list = self.view.portal_list(cx, ids!(list));
        let Some(list) = list.borrow() else { return false };
        list.items().values().any(|item| item.widget.area().rect(cx).contains(abs))
    }

    /// Turns "insert before row `slot`" into a container and index.
    fn target(&self, dragged: usize, slot: usize) -> Option<(Option<String>, usize)> {
        let rows: Vec<(usize, &SidebarRow)> = self.rows.iter().enumerate().filter(|(i, _)| *i != dragged).collect();
        // Position of the slot among the remaining rows.
        let at = rows.iter().take_while(|(i, _)| *i < slot).count();
        let before = &rows[..at];
        let category = match before.last() {
            Some((_, SidebarRow::Category { id, .. })) => Some(id.clone()),
            Some((_, SidebarRow::Channel { category, .. })) => category.clone(),
            None => None,
        };
        let index = match &category {
            Some(cat) => before
                .iter()
                .filter(|(_, r)| matches!(r, SidebarRow::Channel { category: Some(c), .. } if c == cat))
                .count(),
            // Root items: root channels and categories.
            None => before
                .iter()
                .filter(|(_, r)| matches!(r, SidebarRow::Category { .. } | SidebarRow::Channel { category: None, .. }))
                .count(),
        };
        Some((category, index))
    }

    fn show_drop_line(&mut self, cx: &mut Cx, y: Option<f64>) {
        let top = self.view.area().rect(cx).pos.y;
        let mut line = self.view.widget(cx, ids!(drop_line));
        match y {
            Some(y) => {
                let off = (y - top - 1.0).max(0.0);
                script_apply_eval!(cx, line, {margin: mod.prelude.widgets.Inset{top: #(off) left: 8 right: 8}});
                line.set_visible(cx, true);
            }
            None => line.set_visible(cx, false),
        }
        self.view.redraw(cx);
    }

    pub fn handle_list_actions(&mut self, cx: &mut Cx, actions: &Actions) -> Option<ChannelListAction> {
        let list = self.view.portal_list(cx, ids!(list));
        let mut out = None;
        for (i, item) in list.items_with_actions(actions) {
            let view = item.as_view();
            if view.finger_hover_in(actions).is_some() {
                self.hovered = Some(i);
                redraw_items(cx, &list);
            }
            if view.finger_hover_out(actions).is_some() && self.hovered == Some(i) {
                self.hovered = None;
                redraw_items(cx, &list);
            }
            let row = self.rows.get(i).cloned();
            if item.view(cx, ids!(add)).finger_up(actions).is_some_and(|e| !e.cancelled) {
                if let Some(SidebarRow::Category { id, .. }) = row {
                    out = Some(ChannelListAction::CreateIn(id));
                }
                self.drag = None;
                continue;
            }
            if let Some(e) = view.finger_down(actions) {
                if !e.device.is_primary_hit() {
                    out = Some(ChannelListAction::Context { row: row.clone(), at: (e.abs.x, e.abs.y) });
                    self.drag = None;
                    continue;
                }
                if matches!(row, Some(SidebarRow::Channel { .. })) {
                    self.drag = Some(Drag { row: i, start_y: e.abs.y, moving: false, slot: None });
                }
            }
            if let Some(e) = view.finger_move(actions) {
                if let Some(mut d) = self.drag.clone().filter(|d| d.row == i) {
                    if self.can_manage && (e.abs.y - d.start_y).abs() > DRAG_THRESHOLD {
                        d.moving = true;
                    }
                    if d.moving {
                        let slot = self.slot_at(cx, e.abs.y);
                        d.slot = slot.map(|(s, _)| s);
                        self.show_drop_line(cx, slot.map(|(_, y)| y));
                    }
                    self.drag = Some(d);
                }
            }
            if let Some(e) = view.finger_up(actions) {
                let drag = self.drag.take();
                self.show_drop_line(cx, None);
                if drag.as_ref().is_some_and(|d| d.moving) {
                    // The rows are about to move under the pointer.
                    self.hovered = None;
                }
                match (drag, row) {
                    (Some(d), Some(SidebarRow::Channel { id, .. })) if d.moving && d.row == i => {
                        let moved = d
                            .slot
                            .filter(|s| *s != d.row && *s != d.row + 1)
                            .and_then(|s| self.target(d.row, s));
                        if let Some((category, index)) = moved {
                            out = Some(ChannelListAction::Move { id, category, index });
                        }
                    }
                    (_, Some(SidebarRow::Channel { id, voice: false, .. })) if !e.cancelled && e.device.is_primary_hit() => {
                        out = Some(ChannelListAction::Select(id));
                    }
                    _ => {}
                }
            }
        }
        // Right-click on the list's own empty space (rows handle their own).
        if out.is_none() {
            if let Some(ViewAction::FingerDown(e)) = actions.find_widget_action(self.view.widget_uid()).map(|a| a.cast()) {
                if !e.device.is_primary_hit() {
                    out = Some(ChannelListAction::Context { row: None, at: (e.abs.x, e.abs.y) });
                }
            }
        }
        out
    }
}

impl Widget for ChannelList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.rows.len());
            while let Some(i) = list.next_visible_item(cx) {
                let Some(r) = self.rows.get(i) else { continue };
                let hovered = self.hovered == Some(i);
                match r {
                    SidebarRow::Category { name, .. } => {
                        let row = list.item(cx, i, id!(Category));
                        row.label(cx, ids!(label)).set_text(cx, name);
                        row.view(cx, ids!(add)).set_visible(cx, hovered && self.can_manage);
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    SidebarRow::Channel { id, name, voice, encrypted, .. } => {
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

impl MemberList {
    /// Right-click on a member: (row index, window position).
    pub fn context(&self, cx: &mut Cx, actions: &Actions) -> Option<(usize, DVec2)> {
        let list = self.view.portal_list(cx, ids!(list));
        list.items_with_actions(actions).into_iter().find_map(|(i, item)| {
            item.as_view()
                .finger_down(actions)
                .filter(|e| !e.device.is_primary_hit())
                .map(|e| (i, e.abs))
                .filter(|_| matches!(self.rows.get(i), Some(MemberRow::Member { .. })))
        })
    }
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
                    MemberRow::Member { name, initial, color, avatar, .. } => {
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

// ─── Relays (settings) ───────────────────────────────────────────────────

#[derive(Script, ScriptHook, Widget)]
pub struct RelayList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<crate::backend::RelayItem>,
}

impl RelayList {
    /// The relay whose Remove was clicked.
    pub fn removed(&self, cx: &mut Cx, actions: &Actions) -> Option<String> {
        let list = self.view.portal_list(cx, ids!(list));
        list.items_with_actions(actions)
            .into_iter()
            .find(|(_, item)| item.view(cx, ids!(remove)).finger_up(actions).is_some_and(|e| !e.cancelled))
            .and_then(|(i, _)| self.rows.get(i).map(|r| r.url.clone()))
    }
}

impl Widget for RelayList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.rows.len());
            while let Some(i) = list.next_visible_item(cx) {
                let Some(r) = self.rows.get(i) else { continue };
                let row = list.item(cx, i, id!(Relay));
                row.label(cx, ids!(url)).set_text(cx, &r.url);
                let mode = match (r.read, r.write) {
                    (true, true) => "read + write",
                    (true, false) => "read",
                    (false, true) => "write",
                    _ => "off",
                };
                row.label(cx, ids!(mode)).set_text(cx, mode);
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

// ─── Role picker (encrypted channel access) ──────────────────────────────

#[derive(Script, ScriptHook, Widget)]
pub struct RolePicker {
    #[deref]
    view: View,
    /// (role id, name, picked)
    #[rust]
    pub roles: Vec<(String, String, bool)>,
}

impl RolePicker {
    pub fn picked(&self) -> Vec<String> {
        self.roles.iter().filter(|r| r.2).map(|r| r.0.clone()).collect()
    }

    pub fn handle_list_actions(&mut self, cx: &mut Cx, actions: &Actions) {
        let list = self.view.portal_list(cx, ids!(list));
        let hit = list.items_with_actions(actions).into_iter().find(|(_, item)| clicked(item, actions));
        if let Some((i, _)) = hit {
            if let Some(r) = self.roles.get_mut(i) {
                r.2 = !r.2;
            }
            redraw_items(cx, &list);
        }
    }
}

impl Widget for RolePicker {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.roles.len());
            while let Some(i) = list.next_visible_item(cx) {
                let Some((_, name, picked)) = self.roles.get(i) else { continue };
                let row = list.item(cx, i, id!(Role));
                row.label(cx, ids!(mark)).set_text(cx, if *picked { "✓" } else { "·" });
                row.label(cx, ids!(name)).set_text(cx, name);
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}
