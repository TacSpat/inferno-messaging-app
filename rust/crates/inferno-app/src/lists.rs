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
                let img = row.image(cx, ids!(icon.pic));
                crate::images::show(cx, &img, s.picture.as_deref());
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
    /// Make a voice channel an ember of `hearth` (at `index` among its
    /// embers, or last).
    Nest { id: String, hearth: String, index: Option<usize> },
    MoveCategory { id: String, index: usize },
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
/// Rails' channel_reorder_controller: hovering a voice channel this long
/// while dragging offers "Nest as ember".
const NEST_HOVER_SECS: f64 = 0.6;
/// Rails' auto-scroll: within this many points of an edge, at this speed.
const SCROLL_EDGE: f64 = 40.0;
const SCROLL_SPEED: f64 = 8.0;
/// Rails' MAX_DEPTH: three levels.
const MAX_LEVELS: u8 = 3;

#[derive(Script, ScriptHook, Widget)]
pub struct ChannelList {
    #[deref]
    view: View,
    /// The rows shown: `all` less collapsed categories' channels.
    #[rust]
    pub rows: Vec<SidebarRow>,
    #[rust]
    all: Vec<SidebarRow>,
    /// Collapsed category ids (Rails' category-collapse, remembered).
    #[rust]
    collapsed: Option<HashSet<String>>,
    #[rust]
    pub selected: Option<String>,
    /// manage_channels: gears and drag-to-reorder.
    #[rust]
    pub can_manage: bool,
    #[rust]
    hovered: Option<usize>,
    #[rust]
    drag: Option<Drag>,
    /// Hovered voice channel while dragging, and whether "Nest as ember"
    /// is armed (after NEST_HOVER_SECS).
    #[rust]
    nest: Option<(usize, bool)>,
    #[rust]
    nest_timer: Timer,
    #[rust]
    scroll_timer: Timer,
    #[rust]
    scroll_dir: f64,
}

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct SidebarPrefs {
    #[serde(default)]
    collapsed: Vec<String>,
}

impl ChannelList {
    fn collapsed(&mut self) -> &mut HashSet<String> {
        self.collapsed.get_or_insert_with(|| {
            crate::picker::file("sidebar")
                .and_then(|p| std::fs::read(p).ok())
                .and_then(|b| serde_json::from_slice::<SidebarPrefs>(&b).ok())
                .map(|p| p.collapsed.into_iter().collect())
                .unwrap_or_default()
        })
    }

    /// New sidebar rows from the server.
    pub fn set_rows(&mut self, rows: Vec<SidebarRow>) {
        self.all = rows;
        self.refilter();
    }

    /// Hides collapsed categories' channels, except the one we're in
    /// (Discord's touch; Rails hid it too).
    pub fn refilter(&mut self) {
        let collapsed = self.collapsed().clone();
        let selected = self.selected.clone();
        self.rows = self
            .all
            .iter()
            .filter(|r| match r {
                SidebarRow::Channel { id, category: Some(c), .. } => !collapsed.contains(c) || selected.as_deref() == Some(id.as_str()),
                _ => true,
            })
            .cloned()
            .collect();
    }

    fn toggle_category(&mut self, cx: &mut Cx, id: &str) {
        let set = self.collapsed();
        if !set.remove(id) {
            set.insert(id.to_owned());
        }
        let prefs = SidebarPrefs { collapsed: set.iter().cloned().collect() };
        if let (Some(p), Ok(json)) = (crate::picker::file("sidebar"), serde_json::to_vec(&prefs)) {
            if let Some(dir) = p.parent() {
                let _ = std::fs::create_dir_all(dir);
            }
            let _ = std::fs::write(p, json);
        }
        self.refilter();
        self.hovered = None;
        redraw_items(cx, &self.view.portal_list(cx, ids!(list)));
    }

    fn depth(&self, i: usize) -> Option<u8> {
        match self.rows.get(i) {
            Some(SidebarRow::Channel { depth, .. }) => Some(*depth),
            _ => None,
        }
    }

    fn is_voice(&self, i: usize) -> bool {
        matches!(self.rows.get(i), Some(SidebarRow::Channel { voice: true, .. }))
    }

    fn row_id(&self, i: usize) -> Option<String> {
        match self.rows.get(i)? {
            SidebarRow::Channel { id, .. } | SidebarRow::Category { id, .. } => Some(id.clone()),
        }
    }

    /// One past the last row of `i`'s embers (rows that move with it).
    fn subtree_end(&self, i: usize) -> usize {
        let Some(d) = self.depth(i) else { return i + 1 };
        let mut j = i + 1;
        while self.depth(j).is_some_and(|x| x > d) {
            j += 1;
        }
        j
    }

    /// The row of the hearth that ember row `i` sits under.
    fn hearth_row(&self, i: usize) -> Option<usize> {
        let d = self.depth(i)?.checked_sub(1)?;
        (0..i).rev().find(|&j| self.depth(j) == Some(d))
    }

    /// Whether the dragged row may become an ember of row `t`.
    fn can_nest(&self, dragged: usize, t: usize) -> bool {
        let end = self.subtree_end(dragged);
        if !self.is_voice(dragged) || !self.is_voice(t) || (dragged..end).contains(&t) {
            return false;
        }
        let d = self.depth(dragged).unwrap_or(0);
        let below = (dragged..end).filter_map(|j| self.depth(j)).max().unwrap_or(d) - d;
        self.depth(t).unwrap_or(0) + 1 + below < MAX_LEVELS
    }

    /// The row under the pointer at `y`.
    fn row_at_y(&self, cx: &Cx, y: f64) -> Option<usize> {
        let list = self.view.portal_list(cx, ids!(list));
        let list_ref = list.borrow()?;
        list_ref.items().iter().map(|(i, item)| (*i, item.widget.area().rect(cx))).find(|(_, r)| r.size.y > 0.0 && y >= r.pos.y && y < r.pos.y + r.size.y).map(|(i, _)| i)
    }

    fn clear_nest(&mut self, cx: &mut Cx) {
        if self.nest.take().is_some() {
            cx.stop_timer(self.nest_timer);
            redraw_items(cx, &self.view.portal_list(cx, ids!(list)));
        }
    }

    fn stop_scroll(&mut self, cx: &mut Cx) {
        self.scroll_dir = 0.0;
        cx.stop_timer(self.scroll_timer);
        self.scroll_timer = Timer::empty();
    }

    /// What dropping dragged channel row `d` at `slot` does: nest among a
    /// hearth's embers, or move in a category or the top level.
    fn channel_drop(&self, d: usize, slot: usize) -> Option<ChannelListAction> {
        let id = self.row_id(d)?;
        let end = self.subtree_end(d);
        if (d..=end).contains(&slot) {
            return None;
        }
        // Between a hearth's embers: an ember there, in that place.
        if let Some(next_d) = self.depth(slot).filter(|x| *x > 0) {
            if self.is_voice(d) {
                if let Some(h) = self.hearth_row(slot) {
                    let below = (d..end).filter_map(|j| self.depth(j)).max().unwrap_or(0) - self.depth(d).unwrap_or(0);
                    if next_d + below < MAX_LEVELS {
                        let index = (h + 1..slot).filter(|&j| !(d..end).contains(&j) && self.depth(j) == Some(next_d)).count();
                        return Some(ChannelListAction::Nest { id, hearth: self.row_id(h)?, index: Some(index) });
                    }
                }
            }
        }
        let (category, index) = self.target(d, slot)?;
        Some(ChannelListAction::Move { id, category, index })
    }

    /// Dropping category row `c` before row `slot`: its place among the
    /// top-level items (a slot inside a category lands after it).
    fn category_drop(&self, c: usize, slot: usize) -> Option<ChannelListAction> {
        let id = self.row_id(c)?;
        let index = self.rows[..slot.min(self.rows.len())]
            .iter()
            .enumerate()
            .filter(|(j, _)| *j != c)
            .filter(|(_, r)| matches!(r, SidebarRow::Category { .. } | SidebarRow::Channel { category: None, depth: 0, .. }))
            .count();
        Some(ChannelListAction::MoveCategory { id, index })
    }
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
        // Embers ride with their hearth; they don't count as places.
        let rows: Vec<(usize, &SidebarRow)> = self
            .rows
            .iter()
            .enumerate()
            .filter(|(i, r)| !(dragged..self.subtree_end(dragged)).contains(i) && !matches!(r, SidebarRow::Channel { depth, .. } if *depth > 0))
            .collect();
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
                if row.is_some() {
                    self.drag = Some(Drag { row: i, start_y: e.abs.y, moving: false, slot: None });
                }
            }
            if let Some(e) = view.finger_move(actions) {
                if let Some(mut d) = self.drag.clone().filter(|d| d.row == i) {
                    if self.can_manage && (e.abs.y - d.start_y).abs() > DRAG_THRESHOLD {
                        d.moving = true;
                    }
                    if d.moving {
                        // Hover a voice channel to arm nesting (channels only).
                        let over = self.row_at_y(cx, e.abs.y).filter(|&t| self.depth(i).is_some() && self.can_nest(i, t));
                        match (over, self.nest) {
                            (Some(t), Some((n, _))) if n == t => {}
                            (Some(t), _) => {
                                self.clear_nest(cx);
                                self.nest = Some((t, false));
                                self.nest_timer = cx.start_timeout(NEST_HOVER_SECS);
                            }
                            (None, _) => self.clear_nest(cx),
                        }
                        if matches!(self.nest, Some((_, true))) {
                            d.slot = None;
                            self.show_drop_line(cx, None);
                        } else {
                            let slot = self.slot_at(cx, e.abs.y);
                            d.slot = slot.map(|(s, _)| s);
                            self.show_drop_line(cx, slot.map(|(_, y)| y));
                        }
                        // Rails' edge auto-scroll.
                        let r = self.view.area().rect(cx);
                        let dir = if e.abs.y < r.pos.y + SCROLL_EDGE {
                            -1.0
                        } else if e.abs.y > r.pos.y + r.size.y - SCROLL_EDGE {
                            1.0
                        } else {
                            0.0
                        };
                        if dir == 0.0 {
                            self.stop_scroll(cx);
                        } else if self.scroll_dir == 0.0 {
                            self.scroll_dir = dir;
                            self.scroll_timer = cx.start_interval(1.0 / 60.0);
                        } else {
                            self.scroll_dir = dir;
                        }
                    }
                    self.drag = Some(d);
                }
            }
            if let Some(e) = view.finger_up(actions) {
                let drag = self.drag.take();
                let nest = self.nest;
                self.clear_nest(cx);
                self.stop_scroll(cx);
                self.show_drop_line(cx, None);
                if drag.as_ref().is_some_and(|d| d.moving) {
                    // The rows are about to move under the pointer.
                    self.hovered = None;
                }
                match (drag, row) {
                    (Some(d), Some(SidebarRow::Channel { id, .. })) if d.moving && d.row == i => {
                        out = match nest {
                            Some((t, true)) => self.row_id(t).map(|hearth| ChannelListAction::Nest { id, hearth, index: None }),
                            _ => d.slot.and_then(|s| self.channel_drop(d.row, s)),
                        };
                    }
                    (Some(d), Some(SidebarRow::Category { .. })) if d.moving && d.row == i => {
                        out = d.slot.filter(|s| *s != d.row).and_then(|s| self.category_drop(d.row, s));
                    }
                    // Rails: clicking a category header collapses it.
                    (_, Some(SidebarRow::Category { id, .. })) if !e.cancelled && e.device.is_primary_hit() => {
                        self.toggle_category(cx, &id);
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

impl ChannelList {
    fn handle_timers(&mut self, cx: &mut Cx, event: &Event) {
        if self.nest_timer.is_event(event).is_some() {
            if let Some((t, false)) = self.nest {
                self.nest = Some((t, true));
                self.show_drop_line(cx, None);
                redraw_items(cx, &self.view.portal_list(cx, ids!(list)));
            }
        }
        if self.scroll_timer.is_event(event).is_some() && self.scroll_dir != 0.0 {
            let list = self.view.portal_list(cx, ids!(list));
            let (first, scroll) = (list.first_id(), list.borrow().map(|l| l.first_scroll()).unwrap_or(0.0));
            list.set_first_id_and_scroll(first, scroll - self.scroll_dir * SCROLL_SPEED);
            self.view.redraw(cx);
        }
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
                    SidebarRow::Category { id, name } => {
                        let row = list.item(cx, i, id!(Category));
                        row.label(cx, ids!(label)).set_text(cx, name);
                        // Rails' arrow turns -90° when collapsed.
                        let shut = self.collapsed.as_ref().is_some_and(|c| c.contains(id));
                        for (path, on) in [(ids!(open), !shut), (ids!(shut), shut)] {
                            let mut ico = row.widget(cx, path);
                            let c = crate::theme::tok("gray_400", if on { 1.0 } else { 0.0 });
                            script_apply_eval!(cx, ico, {draw_icon +: {color: #(c)}});
                        }
                        row.view(cx, ids!(add)).set_visible(cx, hovered && self.can_manage);
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    SidebarRow::Channel { id, name, voice, encrypted, depth, last, guides, .. } => {
                        let active = self.selected.as_deref() == Some(id.as_str());
                        let row = list.item(cx, i, if active { id!(ActiveChannel) } else { id!(Channel) });
                        let nesting = self.nest == Some((i, true));
                        let mut item = row.widget(cx, ids!(item));
                        let bg = if nesting { crate::theme::tok("accent", 0.15) } else { rgba(0, 0.0) };
                        if !active {
                            script_apply_eval!(cx, item, {draw_bg +: {color: #(bg)}});
                        }
                        row.widget(cx, ids!(item.nest_hint)).set_visible(cx, nesting);
                        if !active {
                            let mut tree = row.widget(cx, ids!(tree));
                            let (w, d) = (*depth as f64 * 26.0, *depth as f64);
                            let l = if *last { 1.0 } else { 0.0 };
                            let g0 = if guides.first().copied().unwrap_or(false) { 1.0 } else { 0.0 };
                            script_apply_eval!(cx, tree, {width: #(w) draw_bg +: {depth: #(d) last: #(l) g0: #(g0)}});
                        }
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
        self.handle_timers(cx, event);
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
    /// Left click on a member: (row index, window position).
    pub fn clicked_member(&self, cx: &mut Cx, actions: &Actions) -> Option<(usize, DVec2)> {
        let list = self.view.portal_list(cx, ids!(list));
        list.items_with_actions(actions).into_iter().find_map(|(i, item)| {
            item.as_view()
                .finger_up(actions)
                .filter(|e| !e.cancelled && e.was_tap() && e.device.is_primary_hit())
                .map(|e| (i, e.abs))
                .filter(|_| matches!(self.rows.get(i), Some(MemberRow::Member { .. })))
        })
    }

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
                    MemberRow::Member { name, initial, color, avatar, picture, .. } => {
                        let row = list.item(cx, i, id!(Member));
                        let img = row.image(cx, ids!(face.avatar.pic));
                        crate::images::show(cx, &img, picture.as_deref());
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

// ─── Server settings lists ───────────────────────────────────────────────

/// Rails' role editor groups (`role_editor_controller.js` PERMISSION_GROUPS).
pub const PERMISSION_GROUPS: &[(&str, &[(&str, &str)])] = &[
    ("General", &[
        ("read_messages", "View channels and read messages"),
        ("read_message_history", "Read message history"),
        ("create_invite", "Create invite links"),
        ("change_nickname", "Change their own nickname in this server"),
    ]),
    ("Text", &[
        ("send_messages", "Send messages in text channels"),
        ("attach_files", "Upload images and files"),
        ("send_gifs", "Send GIFs in messages"),
        ("add_reactions", "Add emoji reactions to messages"),
        ("mention_everyone", "Use @everyone and @here mentions"),
    ]),
    ("Expression", &[
        ("send_custom_emojis", "Use custom server emojis in messages"),
        ("send_custom_stickers", "Use custom server stickers in messages"),
        ("create_emojis", "Upload custom emojis to the server"),
        ("create_stickers", "Upload custom stickers to the server"),
        ("manage_emojis", "Delete emojis and stickers uploaded by others"),
    ]),
    ("Management", &[
        ("manage_messages", "Delete or pin other members' messages"),
        ("manage_channels", "Create, edit, and delete channels"),
        ("manage_roles", "Create, edit, and reorder roles"),
        ("manage_invites", "View and revoke invite links"),
        ("manage_server", "Edit server name, icon, and settings"),
    ]),
    ("Moderation", &[
        ("kick_members", "Remove members from the server"),
        ("ban_members", "Permanently ban members"),
    ]),
    ("Voice", &[
        ("connect_voice", "Join voice channels"),
        ("speak", "Speak in voice channels"),
        ("video", "Send video in voice channels"),
        ("screen_share", "Share their screen in voice channels"),
        ("mute_members", "Server-mute other members in voice"),
        ("deafen_members", "Server-deafen other members in voice"),
        ("move_members", "Move members between voice channels"),
    ]),
    ("Dangerous", &[("administrator", "Full admin access — bypasses all permission checks")]),
];

#[derive(Debug, Clone, PartialEq)]
enum PermRow {
    Header(&'static str),
    Perm { key: &'static str, label: &'static str },
}

fn perm_rows() -> Vec<PermRow> {
    let mut v = Vec::new();
    for (group, perms) in PERMISSION_GROUPS {
        v.push(PermRow::Header(group));
        v.extend(perms.iter().map(|(key, label)| PermRow::Perm { key, label }));
    }
    v
}

/// Permission toggles for the role being edited.
#[derive(Script, ScriptHook, Widget)]
pub struct PermList {
    #[deref]
    view: View,
    #[rust]
    pub granted: Vec<String>,
    #[rust]
    rows: Vec<PermRow>,
    #[rust]
    pub enabled: bool,
}

impl PermList {
    /// Toggles a clicked permission; true if anything changed.
    pub fn handle_list_actions(&mut self, cx: &mut Cx, actions: &Actions) -> bool {
        if !self.enabled {
            return false;
        }
        let list = self.view.portal_list(cx, ids!(list));
        let hit = list.items_with_actions(actions).into_iter().find(|(_, item)| clicked(item, actions));
        if let Some((i, _)) = hit {
            if let Some(PermRow::Perm { key, .. }) = self.rows.get(i) {
                match self.granted.iter().position(|k| k == key) {
                    Some(p) => {
                        self.granted.remove(p);
                    }
                    None => self.granted.push(key.to_string()),
                }
                redraw_items(cx, &list);
                return true;
            }
        }
        false
    }
}

impl Widget for PermList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        if self.rows.is_empty() {
            self.rows = perm_rows();
        }
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.rows.len());
            while let Some(i) = list.next_visible_item(cx) {
                match self.rows.get(i) {
                    Some(PermRow::Header(g)) => {
                        let row = list.item(cx, i, id!(Group));
                        row.set_text(cx, &g.to_uppercase());
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    Some(PermRow::Perm { key, label }) => {
                        let row = list.item(cx, i, id!(Perm));
                        let on = self.granted.iter().any(|k| k == key);
                        // Rails: the key, title-cased, over its description.
                        let title: String = key
                            .split('_')
                            .map(|w| {
                                let mut c = w.chars();
                                c.next().map(|f| f.to_uppercase().chain(c).collect::<String>()).unwrap_or_default()
                            })
                            .collect::<Vec<_>>()
                            .join(" ");
                        row.label(cx, ids!(text.title)).set_text(cx, &title);
                        row.label(cx, ids!(text.label)).set_text(cx, label);
                        let switch = row.widget(cx, ids!(switch));
                        set_switch(cx, &switch, on, self.enabled);
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

/// Rails' toggle switch (w-11 h-6, white knob; green when on), drawn on
/// a `Switch` view: track colour and knob side.
pub fn set_switch(cx: &mut Cx, switch: &WidgetRef, on: bool, enabled: bool) {
    let mut track = switch.clone();
    let alpha = if enabled { 1.0 } else { 0.5 };
    let color = if on { rgba(0x16a34a, alpha) } else { crate::theme::tok("gray_600", alpha) };
    let x = if on { 1.0 } else { 0.0 };
    script_apply_eval!(cx, track, {draw_bg +: {color: #(color)} align: mod.prelude.widgets.Align{x: #(x) y: 0.5}});
}

#[derive(Debug, Clone, PartialEq)]
pub enum RoleListAction {
    Select(usize),
    /// Drop row `from` before row `to` (row indices).
    Move { from: usize, to: usize },
}

/// Roles, highest first; one is selected for editing. Rows below `rank`
/// drag to reorder (Flutter's hierarchy rule); @everyone stays last.
#[derive(Script, ScriptHook, Widget)]
pub struct RoleList {
    #[deref]
    view: View,
    #[rust]
    pub roles: Vec<crate::backend::RoleForm>,
    #[rust]
    pub selected: usize,
    #[rust]
    pub rank: i64,
    #[rust]
    drag: Option<Drag>,
}

impl RoleList {
    fn movable(&self, i: usize) -> bool {
        self.roles.get(i).is_some_and(|r| !r.everyone && r.position < self.rank)
    }

    /// The row slot under `y` and the y of its drop line.
    fn slot_at(&self, cx: &Cx, y: f64) -> Option<(usize, f64)> {
        let list = self.view.portal_list(cx, ids!(list));
        let list_ref = list.borrow()?;
        let mut rects: Vec<(usize, Rect)> =
            list_ref.items().iter().map(|(i, item)| (*i, item.widget.area().rect(cx))).filter(|(_, r)| r.size.y > 0.0).collect();
        rects.sort_by_key(|(i, _)| *i);
        for (i, r) in &rects {
            if y < r.pos.y + r.size.y / 2.0 {
                return Some((*i, r.pos.y));
            }
        }
        let last = rects.last()?;
        Some((last.0 + 1, last.1.pos.y + last.1.size.y))
    }

    fn show_drop_line(&mut self, cx: &mut Cx, y: Option<f64>) {
        let top = self.view.area().rect(cx).pos.y;
        let mut line = self.view.widget(cx, ids!(drop_line));
        match y {
            Some(y) => {
                let off = (y - top - 1.0).max(0.0);
                script_apply_eval!(cx, line, {margin: mod.prelude.widgets.Inset{top: #(off)}});
                line.set_visible(cx, true);
            }
            None => line.set_visible(cx, false),
        }
        self.view.redraw(cx);
    }

    pub fn handle_list_actions(&mut self, cx: &mut Cx, actions: &Actions) -> Option<RoleListAction> {
        let list = self.view.portal_list(cx, ids!(list));
        let mut out = None;
        for (i, item) in list.items_with_actions(actions) {
            let view = item.as_view();
            if let Some(e) = view.finger_down(actions) {
                if e.device.is_primary_hit() {
                    self.drag = Some(Drag { row: i, start_y: e.abs.y, moving: false, slot: None });
                }
            }
            if let Some(e) = view.finger_move(actions) {
                if let Some(mut d) = self.drag.clone().filter(|d| d.row == i) {
                    if self.movable(i) && (e.abs.y - d.start_y).abs() > DRAG_THRESHOLD {
                        d.moving = true;
                    }
                    if d.moving {
                        // Only between rows we may move things among.
                        let slot = self.slot_at(cx, e.abs.y).filter(|(s, _)| *s == 0 || self.movable(*s) || self.movable(s - 1));
                        d.slot = slot.map(|(s, _)| s);
                        self.show_drop_line(cx, slot.map(|(_, y)| y));
                    }
                    self.drag = Some(d);
                }
            }
            if let Some(e) = view.finger_up(actions) {
                let drag = self.drag.take();
                self.show_drop_line(cx, None);
                match drag {
                    Some(d) if d.moving && d.row == i => {
                        if let Some(to) = d.slot.filter(|s| *s != d.row && *s != d.row + 1) {
                            out = Some(RoleListAction::Move { from: d.row, to });
                        }
                    }
                    _ if !e.cancelled => out = Some(RoleListAction::Select(i)),
                    _ => {}
                }
            }
        }
        out
    }
}

impl Widget for RoleList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.roles.len());
            while let Some(i) = list.next_visible_item(cx) {
                let Some(r) = self.roles.get(i) else { continue };
                let row = list.item(cx, i, if i == self.selected { id!(Selected) } else { id!(Role) });
                let mut dot = row.widget(cx, ids!(dot));
                let c = rgba(u32::from_str_radix(r.color.trim_start_matches('#'), 16).unwrap_or(0x99aab5), 1.0);
                script_apply_eval!(cx, dot, {draw_bg +: {color: #(c)}});
                row.label(cx, ids!(name)).set_text(cx, &r.name);
                row.label(cx, ids!(count)).set_text(cx, &r.member_count.to_string());
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

/// Rows with a name, a detail line and up to two buttons (members, bans).
#[derive(Debug, Clone, PartialEq)]
pub struct PersonRow {
    pub id: String,
    pub name: String,
    pub detail: String,
    pub a: Option<String>,
    pub b: Option<String>,
}

#[derive(Script, ScriptHook, Widget)]
pub struct PeopleList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<PersonRow>,
}

impl PeopleList {
    /// (row id, which button: 0 = a, 1 = b)
    pub fn pressed(&self, cx: &mut Cx, actions: &Actions) -> Option<(String, u8)> {
        let list = self.view.portal_list(cx, ids!(list));
        for (i, item) in list.items_with_actions(actions) {
            for (path, n) in [(ids!(btn_a), 0u8), (ids!(btn_b), 1u8)] {
                if item.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled) {
                    return self.rows.get(i).map(|r| (r.id.clone(), n));
                }
            }
        }
        None
    }
}

impl Widget for PeopleList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            let count = self.rows.len().max(1);
            list.set_item_range(cx, 0, count);
            while let Some(i) = list.next_visible_item(cx) {
                match self.rows.get(i) {
                    Some(r) => {
                        let row = list.item(cx, i, id!(Person));
                        row.label(cx, ids!(name)).set_text(cx, &r.name);
                        row.label(cx, ids!(detail)).set_text(cx, &r.detail);
                        for (path, label_path, text) in
                            [(ids!(btn_a), ids!(btn_a.t), &r.a), (ids!(btn_b), ids!(btn_b.t), &r.b)]
                        {
                            row.view(cx, path).set_visible(cx, text.is_some());
                            row.label(cx, label_path).set_text(cx, text.as_deref().unwrap_or(""));
                        }
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    None if i == 0 => {
                        list.item(cx, i, id!(Empty)).draw_all(cx, &mut Scope::empty());
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

// ─── Search results ──────────────────────────────────────────────────────

pub use crate::time_fmt::{date_long, date_time};

#[derive(Script, ScriptHook, Widget)]
pub struct ResultList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<crate::backend::SearchRow>,
}

impl ResultList {
    pub fn clicked(&self, cx: &mut Cx, actions: &Actions) -> Option<crate::backend::SearchRow> {
        let list = self.view.portal_list(cx, ids!(list));
        list.items_with_actions(actions)
            .into_iter()
            .find(|(_, item)| clicked(item, actions))
            .and_then(|(i, _)| self.rows.get(i).cloned())
    }
}

impl Widget for ResultList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            let count = self.rows.len().max(1);
            list.set_item_range(cx, 0, count);
            while let Some(i) = list.next_visible_item(cx) {
                match self.rows.get(i) {
                    Some(r) => {
                        let row = list.item(cx, i, id!(Hit));
                        row.label(cx, ids!(channel)).set_text(cx, &format!("# {}", r.channel_name));
                        let mut name = row.widget(cx, ids!(head.author));
                        let c = rgba(r.color, 1.0);
                        script_apply_eval!(cx, name, {draw_text +: {color: #(c)}});
                        name.set_text(cx, &r.author);
                        row.label(cx, ids!(head.time)).set_text(cx, &date_time(r.at));
                        row.label(cx, ids!(body)).set_text(cx, &r.body);
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    None if i == 0 => list.item(cx, i, id!(Empty)).draw_all(cx, &mut Scope::empty()),
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


// ─── Members page ────────────────────────────────────────────────────────

use crate::backend::MemberInfo;
use std::collections::HashSet;

/// Draws a `CheckBox16` on or off (visibility doesn't stick on icons in
/// list rows, so the mark is coloured in or out).
pub fn set_check(cx: &mut Cx, check: &WidgetRef, on: bool) {
    let mut c = check.clone();
    let bg = if on { crate::theme::tok("accent", 1.0) } else { crate::theme::tok("gray_900", 1.0) };
    script_apply_eval!(cx, c, {draw_bg +: {color: #(bg)}});
    let mut mark = check.widget(cx, ids!(mark));
    let fg = rgba(0xffffff, if on { 1.0 } else { 0.0 });
    script_apply_eval!(cx, mark, {draw_icon +: {color: #(fg)}});
}

#[derive(Debug, Clone, PartialEq)]
pub enum MemberAdminAction {
    /// Checkbox: (pubkey).
    Check(String),
    Roles(String, DVec2),
    Timeout(String, DVec2),
    RemoveTimeout(String),
    Kick(String),
    Ban(String),
}

/// Rails' members list: checkbox, avatar, name with a Timed out badge,
/// joined date, role chips, and the moderation buttons we're allowed.
#[derive(Script, ScriptHook, Widget)]
pub struct MemberAdminList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<MemberInfo>,
    #[rust]
    pub selected: HashSet<String>,
    #[rust]
    pub can_roles: bool,
    #[rust]
    pub can_kick: bool,
    #[rust]
    pub can_ban: bool,
}

impl MemberAdminList {
    pub fn handle_list_actions(&mut self, cx: &mut Cx, actions: &Actions) -> Option<MemberAdminAction> {
        let list = self.view.portal_list(cx, ids!(list));
        for (i, item) in list.items_with_actions(actions) {
            let Some(r) = self.rows.get(i) else { continue };
            let pk = r.pubkey.clone();
            let up = |path: &[LiveId]| item.view(cx, path).finger_up(actions).filter(|e| !e.cancelled).map(|e| e.abs);
            if up(ids!(slot.check)).is_some() {
                if !self.selected.remove(&pk) {
                    self.selected.insert(pk.clone());
                }
                redraw_items(cx, &list);
                return Some(MemberAdminAction::Check(pk));
            }
            if let Some(at) = up(ids!(actions.roles)) {
                return Some(MemberAdminAction::Roles(pk, at));
            }
            if let Some(at) = up(ids!(actions.timeout)) {
                return Some(if r.timed_out_until.is_some() { MemberAdminAction::RemoveTimeout(pk) } else { MemberAdminAction::Timeout(pk, at) });
            }
            if up(ids!(actions.kick)).is_some() {
                return Some(MemberAdminAction::Kick(pk));
            }
            if up(ids!(actions.ban)).is_some() {
                return Some(MemberAdminAction::Ban(pk));
            }
        }
        None
    }
}

impl Widget for MemberAdminList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.rows.len().max(1));
            while let Some(i) = list.next_visible_item(cx) {
                let Some(r) = self.rows.get(i) else {
                    if i == 0 {
                        list.item(cx, i, id!(Empty)).draw_all(cx, &mut Scope::empty());
                    }
                    continue;
                };
                let row = list.item(cx, i, id!(Member));
                let moderatable = !r.owner && !r.me && (self.can_kick || self.can_ban);
                let check = row.widget(cx, ids!(slot.check));
                check.set_visible(cx, moderatable);
                let on = self.selected.contains(&r.pubkey);
                set_check(cx, &check, on);
                let mut av = row.widget(cx, ids!(avatar));
                let fill = rgba(r.avatar, 1.0);
                script_apply_eval!(cx, av, {draw_bg +: {color: #(fill)}});
                row.label(cx, ids!(avatar.initial)).set_text(cx, &r.initial);
                let img = row.image(cx, ids!(avatar.pic));
                crate::images::show(cx, &img, r.picture.as_deref());
                row.label(cx, ids!(info.top.name)).set_text(cx, &r.name);
                row.view(cx, ids!(info.top.timed_out)).set_visible(cx, r.timed_out_until.is_some());
                let joined = r.joined_at.map(|t| format!("Joined {}", crate::time_fmt::date_short(t))).unwrap_or_default();
                let sub = if r.owner { if joined.is_empty() { "Server owner".to_owned() } else { format!("Server owner · {joined}") } } else { joined };
                row.label(cx, ids!(info.sub)).set_text(cx, &sub);
                // Up to three role chips, then "+n"; @everyone when none.
                let chips: Vec<(String, u32)> =
                    if r.roles.is_empty() { vec![("@everyone".into(), 0x99aab5)] } else { r.roles.iter().take(3).cloned().collect() };
                for (k, path) in [ids!(chips.c0), ids!(chips.c1), ids!(chips.c2)].into_iter().enumerate() {
                    let chip = row.widget(cx, path);
                    match chips.get(k) {
                        Some((name, color)) => {
                            chip.set_visible(cx, true);
                            let mut dot = row.widget(cx, &[path[0], path[1], id!(dot)]);
                            let col = rgba(*color, 1.0);
                            script_apply_eval!(cx, dot, {draw_bg +: {color: #(col)}});
                            row.label(cx, &[path[0], path[1], id!(name)]).set_text(cx, name);
                        }
                        None => chip.set_visible(cx, false),
                    }
                }
                let more = r.roles.len().saturating_sub(3);
                row.label(cx, ids!(chips.more)).set_text(cx, &if more > 0 { format!("+{more}") } else { String::new() });
                row.view(cx, ids!(actions.roles)).set_visible(cx, self.can_roles && !r.owner);
                row.view(cx, ids!(actions.timeout)).set_visible(cx, moderatable && self.can_kick);
                row.label(cx, ids!(actions.timeout.t)).set_text(cx, if r.timed_out_until.is_some() { "Remove Timeout" } else { "Timeout" });
                row.view(cx, ids!(actions.kick)).set_visible(cx, moderatable && self.can_kick);
                row.view(cx, ids!(actions.ban)).set_visible(cx, moderatable && self.can_ban);
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

// ─── Expression pages ────────────────────────────────────────────────────

use crate::backend::CustomItem;

/// Rails' emoji list (two to a row) or sticker grid (four to a row), with
/// delete for `manage_emojis`.
#[derive(Script, ScriptHook, Widget)]
pub struct CustomList {
    #[deref]
    view: View,
    #[rust]
    pub items: Vec<CustomItem>,
    #[rust]
    pub can_delete: bool,
    #[live]
    stickers: bool,
}

impl CustomList {
    fn per_row(&self) -> usize {
        if self.stickers { 4 } else { 2 }
    }

    /// The name of the item whose delete button was clicked.
    pub fn deleted(&self, cx: &mut Cx, actions: &Actions) -> Option<String> {
        let list = self.view.portal_list(cx, ids!(list));
        for (row, item) in list.items_with_actions(actions) {
            for col in 0..self.per_row() {
                let cell = [id!(i0), id!(i1), id!(i2), id!(i3)][col];
                if item.view(cx, &[cell, id!(delete)]).finger_up(actions).is_some_and(|e| !e.cancelled) {
                    return self.items.get(row * self.per_row() + col).map(|i| i.name.clone());
                }
            }
        }
        None
    }
}

impl Widget for CustomList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        let per = self.per_row();
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.items.len().div_ceil(per).max(1));
            while let Some(i) = list.next_visible_item(cx) {
                if self.items.is_empty() {
                    if i == 0 {
                        list.item(cx, i, id!(Empty)).draw_all(cx, &mut Scope::empty());
                    }
                    continue;
                }
                let row = list.item(cx, i, id!(Row));
                for col in 0..per {
                    let cell_id = [id!(i0), id!(i1), id!(i2), id!(i3)][col];
                    let cell = row.view(cx, &[cell_id]);
                    let Some(it) = self.items.get(i * per + col) else {
                        cell.set_visible(cx, false);
                        continue;
                    };
                    cell.set_visible(cx, true);
                    let img = cell.image(cx, ids!(img));
                    crate::images::show(cx, &img, Some(it.url.as_str()));
                    let name = if self.stickers { it.name.clone() } else { format!(":{}:", it.name) };
                    cell.label(cx, ids!(name)).set_text(cx, &name);
                    let by = if it.by.is_empty() { String::new() } else if self.stickers { format!("by {}", it.by) } else { format!("uploaded by {}", it.by) };
                    cell.label(cx, ids!(by)).set_text(cx, &by);
                    if self.stickers {
                        cell.label(cx, ids!(desc)).set_text(cx, &it.description);
                        cell.widget(cx, ids!(desc)).set_visible(cx, !it.description.is_empty());
                    }
                    cell.view(cx, ids!(delete)).set_visible(cx, self.can_delete);
                }
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

// ─── Audit log ───────────────────────────────────────────────────────────

use crate::backend::AuditItem;

/// Rails' audit log rows: a tinted icon by kind, "actor did something",
/// and when.
#[derive(Script, ScriptHook, Widget)]
pub struct AuditList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<AuditItem>,
}

impl Widget for AuditList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        let now = chrono::Utc::now().timestamp();
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.rows.len().max(1));
            while let Some(i) = list.next_visible_item(cx) {
                let Some(r) = self.rows.get(i) else {
                    if i == 0 {
                        list.item(cx, i, id!(Empty)).draw_all(cx, &mut Scope::empty());
                    }
                    continue;
                };
                let row = list.item(cx, i, id!(Entry));
                // blue, purple, green, amber, red, cyan (Rails' -400s).
                let color = [0x60a5fa, 0xc084fc, 0x4ade80, 0xfbbf24, 0xf87171, 0x22d3ee][r.tone.min(5) as usize];
                let mut badge = row.widget(cx, ids!(badge));
                let (bg, fg) = (rgba(color, 0.2), rgba(color, 1.0));
                script_apply_eval!(cx, badge, {draw_bg +: {color: #(bg)}});
                let icon = match r.tone { 2 => 1, 4 => 2, 5 => 3, _ => 0 };
                for (k, path) in [ids!(badge.edit), ids!(badge.user), ids!(badge.ban), ids!(badge.link)].into_iter().enumerate() {
                    let mut ico = row.widget(cx, path);
                    let c = if k == icon { fg } else { rgba(0, 0.0) };
                    script_apply_eval!(cx, ico, {draw_icon +: {color: #(c)}});
                }
                row.label(cx, ids!(text.line.actor)).set_text(cx, &r.actor);
                row.label(cx, ids!(text.line.what)).set_text(cx, &r.text);
                let when = format!("{} ago · {}", crate::time_fmt::in_words(now - r.at), crate::time_fmt::date_time(r.at));
                row.label(cx, ids!(text.when)).set_text(cx, &when);
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

// ─── Discovery ───────────────────────────────────────────────────────────

/// Flutter's server catalog: cards three to a row.
#[derive(Script, ScriptHook, Widget)]
pub struct DiscoverList {
    #[deref]
    view: View,
    #[rust]
    pub servers: Vec<inferno_core::session::Listing>,
    #[rust]
    pub searching: bool,
}

const PER_ROW: usize = 3;

impl DiscoverList {
    /// The listing whose card was clicked.
    pub fn clicked(&self, cx: &mut Cx, actions: &Actions) -> Option<inferno_core::session::Listing> {
        let list = self.view.portal_list(cx, ids!(list));
        for (row, item) in list.items_with_actions(actions) {
            for (col, path) in [ids!(c0), ids!(c1), ids!(c2)].into_iter().enumerate() {
                if item.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled && e.was_tap()) {
                    return self.servers.get(row * PER_ROW + col).cloned();
                }
            }
        }
        None
    }
}

impl Widget for DiscoverList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            let rows = self.servers.len().div_ceil(PER_ROW).max(1);
            list.set_item_range(cx, 0, rows);
            while let Some(i) = list.next_visible_item(cx) {
                if self.servers.is_empty() {
                    if i == 0 {
                        let empty = list.item(cx, i, id!(Empty));
                        let text = if self.searching { "Searching relays…" } else { "No public servers found on your relays" };
                        empty.label(cx, ids!(text)).set_text(cx, text);
                        empty.draw_all(cx, &mut Scope::empty());
                    }
                    continue;
                }
                let row = list.item(cx, i, id!(Row));
                for (col, path) in [ids!(c0), ids!(c1), ids!(c2)].into_iter().enumerate() {
                    let card = row.view(cx, path);
                    let Some(s) = self.servers.get(i * PER_ROW + col) else {
                        card.set_visible(cx, false);
                        continue;
                    };
                    card.set_visible(cx, true);
                    let initial = s.name.chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_default();
                    card.label(cx, ids!(banner.initial)).set_text(cx, &initial);
                    card.widget(cx, ids!(banner.initial)).set_visible(cx, s.banner.is_none());
                    let img = card.image(cx, ids!(banner.img));
                    crate::images::show(cx, &img, s.banner.as_deref());
                    card.view(cx, ids!(banner.joined)).set_visible(cx, s.joined);
                    card.label(cx, ids!(head.icon.initial)).set_text(cx, &initial);
                    let img = card.image(cx, ids!(head.icon.pic));
                    crate::images::show(cx, &img, s.picture.as_deref());
                    card.label(cx, ids!(head.name)).set_text(cx, &s.name);
                    let about: String = s.about.chars().take(90).collect();
                    let about = if s.about.chars().count() > 90 { format!("{about}…") } else { about };
                    card.label(cx, ids!(about)).set_text(cx, &about);
                    card.widget(cx, ids!(about)).set_visible(cx, !about.is_empty());
                    let ty = match s.server_type.as_str() {
                        "friends_family" => "Friends & Family",
                        "gaming" => "Gaming",
                        "work_team" => "Work & Team",
                        "adult" => "18+",
                        _ => "Community",
                    };
                    card.label(cx, ids!(tags.ty.label)).set_text(cx, ty);
                    card.view(cx, ids!(tags.age)).set_visible(cx, s.age_restricted && s.server_type != "adult");
                }
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

// ─── DM sidebar ──────────────────────────────────────────────────────────

/// Rails' `_dm_sidebar`: 32px avatar, name, unread badge (99+ cap).
#[derive(Script, ScriptHook, Widget)]
pub struct DmList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<crate::backend::DmRow>,
    /// The open conversation's pubkey.
    #[rust]
    pub selected: Option<String>,
}

impl DmList {
    /// Left click: the row index.
    pub fn clicked(&self, cx: &mut Cx, actions: &Actions) -> Option<usize> {
        let list = self.view.portal_list(cx, ids!(list));
        list.items_with_actions(actions).into_iter().find_map(|(i, item)| {
            item.as_view()
                .finger_up(actions)
                .filter(|e| !e.cancelled && e.device.is_primary_hit())
                .map(|_| i)
                .filter(|i| *i < self.rows.len())
        })
    }

    /// Right click: (row index, window position).
    pub fn context(&self, cx: &mut Cx, actions: &Actions) -> Option<(usize, DVec2)> {
        let list = self.view.portal_list(cx, ids!(list));
        list.items_with_actions(actions).into_iter().find_map(|(i, item)| {
            item.as_view()
                .finger_down(actions)
                .filter(|e| !e.device.is_primary_hit())
                .map(|e| (i, e.abs))
                .filter(|(i, _)| *i < self.rows.len())
        })
    }
}

impl Widget for DmList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.rows.len());
            while let Some(i) = list.next_visible_item(cx) {
                let Some(r) = self.rows.get(i) else { continue };
                let mut row = list.item(cx, i, id!(Conv));
                let active = self.selected.as_deref() == Some(r.person.pubkey.as_str());
                let bg = if active { crate::theme::tok("gray_700", 1.0) } else { rgba(0, 0.0) };
                script_apply_eval!(cx, row, {draw_bg +: {color: #(bg)}});
                let mut face = row.widget(cx, ids!(avatar));
                let a = rgba(r.person.avatar, 1.0);
                script_apply_eval!(cx, face, {draw_bg +: {color: #(a)}});
                row.label(cx, ids!(avatar.initial)).set_text(cx, &r.person.initial);
                let img = row.image(cx, ids!(avatar.pic));
                crate::images::show(cx, &img, r.person.picture.as_deref());
                let mut name = row.widget(cx, ids!(name));
                let c = if active || r.unread > 0 { rgba(0xffffff, 1.0) } else { crate::theme::tok("gray_400", 1.0) };
                script_apply_eval!(cx, name, {draw_text +: {color: #(c)}});
                name.set_text(cx, &r.person.name);
                row.view(cx, ids!(badge)).set_visible(cx, r.unread > 0);
                let n = if r.unread > 99 { "99+".to_owned() } else { r.unread.to_string() };
                row.label(cx, ids!(badge.count)).set_text(cx, &n);
                row.draw_all(cx, &mut Scope::empty());
            }
        }
        DrawStep::done()
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        self.view.handle_event(cx, event, scope);
    }
}

// ─── Friends page ────────────────────────────────────────────────────────

/// What a person row on the friends page offers.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FriendKind {
    Friend,
    Incoming,
    Outgoing,
    Blocked,
    /// A Find People result.
    Found,
}

#[derive(Debug, Clone, PartialEq)]
pub enum FriendRow {
    /// Rails' "INCOMING — 2" section heads.
    Header(String),
    Person { person: crate::backend::Person, sub: String, kind: FriendKind },
    Empty(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FriendButton {
    Message,
    Add,
    Accept,
    Decline,
    Remove,
    Unblock,
}

const FRIEND_BUTTONS: [(&[LiveId], FriendButton); 6] = [
    (ids!(msg_btn), FriendButton::Message),
    (ids!(add_btn), FriendButton::Add),
    (ids!(accept_btn), FriendButton::Accept),
    (ids!(decline_btn), FriendButton::Decline),
    (ids!(remove_btn), FriendButton::Remove),
    (ids!(unblock_btn), FriendButton::Unblock),
];

#[derive(Script, ScriptHook, Widget)]
pub struct FriendList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<FriendRow>,
}

impl FriendList {
    /// A button pressed on a person row: (their pubkey, which).
    pub fn pressed(&self, cx: &mut Cx, actions: &Actions) -> Option<(String, FriendButton)> {
        let list = self.view.portal_list(cx, ids!(list));
        for (i, item) in list.items_with_actions(actions) {
            let Some(FriendRow::Person { person, .. }) = self.rows.get(i) else { continue };
            for (path, b) in FRIEND_BUTTONS {
                if item.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled) {
                    return Some((person.pubkey.clone(), b));
                }
            }
        }
        None
    }
}

impl Widget for FriendList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.rows.len());
            while let Some(i) = list.next_visible_item(cx) {
                match self.rows.get(i) {
                    Some(FriendRow::Header(t)) => {
                        let row = list.item(cx, i, id!(Head));
                        row.set_text(cx, t);
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    Some(FriendRow::Empty(t)) => {
                        let row = list.item(cx, i, id!(Empty));
                        row.label(cx, ids!(text)).set_text(cx, t);
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    Some(FriendRow::Person { person, sub, kind }) => {
                        let row = list.item(cx, i, id!(Person));
                        let mut face = row.widget(cx, ids!(avatar));
                        let a = rgba(person.avatar, 1.0);
                        script_apply_eval!(cx, face, {draw_bg +: {color: #(a)}});
                        row.label(cx, ids!(avatar.initial)).set_text(cx, &person.initial);
                        let img = row.image(cx, ids!(avatar.pic));
                        crate::images::show(cx, &img, person.picture.as_deref());
                        row.label(cx, ids!(name)).set_text(cx, &person.name);
                        row.label(cx, ids!(sub)).set_text(cx, sub);
                        use FriendButton::*;
                        let shown: &[FriendButton] = match kind {
                            FriendKind::Friend => &[Message, Remove],
                            FriendKind::Incoming => &[Accept, Decline],
                            FriendKind::Outgoing => &[Remove],
                            FriendKind::Blocked => &[Unblock],
                            FriendKind::Found => &[Message, Add],
                        };
                        for (path, b) in FRIEND_BUTTONS {
                            row.view(cx, path).set_visible(cx, shown.contains(&b));
                        }
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

// ─── Emoji / sticker picker ──────────────────────────────────────────────

/// What a click in the picker picked.
#[derive(Debug, Clone, PartialEq)]
pub enum Pick {
    Cell(crate::picker::Cell),
    /// (name, url)
    Sticker(String, String),
    /// A section header: collapse or expand it.
    Toggle(String),
    Tile(crate::picker::GifTile),
    /// Send this GIF.
    Gif(inferno_core::gifs::Gif),
    /// Its 🔥: favorite or unfavorite.
    Fire(inferno_core::gifs::Gif),
    /// Right-click on a GIF, at a window position.
    GifMenu(inferno_core::gifs::Gif, DVec2),
    /// Right-click on a collection tile (its id).
    TileMenu(String, DVec2),
}

const TILE_SLOTS: [&[LiveId]; 2] = [ids!(g0), ids!(g1)];

const CELL_SLOTS: [&[LiveId]; 9] = [ids!(c0), ids!(c1), ids!(c2), ids!(c3), ids!(c4), ids!(c5), ids!(c6), ids!(c7), ids!(c8)];
const STICKER_SLOTS: [&[LiveId]; 3] = [ids!(s0), ids!(s1), ids!(s2)];

#[derive(Script, ScriptHook, Widget)]
pub struct PickerList {
    #[deref]
    view: View,
    #[rust]
    pub rows: Vec<crate::picker::Row>,
}

impl PickerList {
    pub fn picked(&self, cx: &mut Cx, actions: &Actions) -> Option<Pick> {
        use crate::picker::Row;
        let list = self.view.portal_list(cx, ids!(list));
        for (i, item) in list.items_with_actions(actions) {
            let tapped = |path: &[LiveId]| item.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled);
            match self.rows.get(i) {
                Some(Row::Header { key, .. }) if item.as_view().finger_up(actions).is_some_and(|e| !e.cancelled) => {
                    return Some(Pick::Toggle(key.clone()));
                }
                Some(Row::Cells(cells)) => {
                    for (k, slot) in CELL_SLOTS.iter().enumerate() {
                        if k < cells.len() && tapped(slot) {
                            return Some(Pick::Cell(cells[k].clone()));
                        }
                    }
                }
                Some(Row::Stickers(st)) => {
                    for (k, slot) in STICKER_SLOTS.iter().enumerate() {
                        if k < st.len() && tapped(slot) {
                            return Some(Pick::Sticker(st[k].0.clone(), st[k].1.clone()));
                        }
                    }
                }
                Some(Row::Tiles(tiles)) => {
                    for (k, slot) in TILE_SLOTS.iter().enumerate() {
                        let Some(tile) = tiles.get(k) else { continue };
                        if let Some(e) = item.view(cx, slot).finger_down(actions).filter(|e| !e.device.is_primary_hit()) {
                            if let crate::picker::GifTile::Collection { id, .. } = tile {
                                return Some(Pick::TileMenu(id.clone(), e.abs));
                            }
                        }
                        if tapped(slot) {
                            return Some(Pick::Tile(tile.clone()));
                        }
                    }
                }
                Some(Row::Gifs(gifs)) => {
                    for (k, slot) in TILE_SLOTS.iter().enumerate() {
                        let Some((gif, _)) = gifs.get(k) else { continue };
                        if tapped(&[slot[0], id!(fire)]) {
                            return Some(Pick::Fire(gif.clone()));
                        }
                        if let Some(e) = item.view(cx, slot).finger_down(actions).filter(|e| !e.device.is_primary_hit()) {
                            return Some(Pick::GifMenu(gif.clone(), e.abs));
                        }
                        if tapped(slot) {
                            return Some(Pick::Gif(gif.clone()));
                        }
                    }
                }
                _ => {}
            }
        }
        None
    }
}

impl Widget for PickerList {
    fn draw_walk(&mut self, cx: &mut Cx2d, scope: &mut Scope, walk: Walk) -> DrawStep {
        use crate::picker::{Cell, Row};
        while let Some(item) = self.view.draw_walk(cx, scope, walk).step() {
            let Some(mut list) = item.borrow_mut::<PortalList>() else { continue };
            list.set_item_range(cx, 0, self.rows.len());
            while let Some(i) = list.next_visible_item(cx) {
                match self.rows.get(i) {
                    Some(Row::Header { title, collapsed, .. }) => {
                        let row = list.item(cx, i, id!(Head));
                        row.view(cx, ids!(open)).set_visible(cx, !*collapsed);
                        row.view(cx, ids!(shut)).set_visible(cx, *collapsed);
                        row.label(cx, ids!(title)).set_text(cx, &title.to_uppercase());
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    Some(Row::Cells(cells)) => {
                        let row = list.item(cx, i, id!(Cells));
                        for (k, slot) in CELL_SLOTS.iter().enumerate() {
                            let view = row.view(cx, slot);
                            let glyph = row.label(cx, &[slot[0], id!(glyph)]);
                            let img = row.image(cx, &[slot[0], id!(img)]);
                            match cells.get(k) {
                                Some(Cell::Unicode(s)) => {
                                    view.set_visible(cx, true);
                                    glyph.set_text(cx, s);
                                    img.set_visible(cx, false);
                                }
                                Some(Cell::Custom { url, .. }) => {
                                    view.set_visible(cx, true);
                                    glyph.set_text(cx, "");
                                    crate::images::show(cx, &img, Some(url));
                                }
                                None => view.set_visible(cx, false),
                            }
                        }
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    Some(Row::Stickers(st)) => {
                        let row = list.item(cx, i, id!(Stickers));
                        for (k, slot) in STICKER_SLOTS.iter().enumerate() {
                            let view = row.view(cx, slot);
                            let img = row.image(cx, &[slot[0], id!(img)]);
                            match st.get(k) {
                                Some((_, url)) => {
                                    view.set_visible(cx, true);
                                    crate::images::show(cx, &img, Some(url));
                                }
                                None => view.set_visible(cx, false),
                            }
                        }
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    Some(Row::Tiles(tiles)) => {
                        use crate::picker::GifTile;
                        let row = list.item(cx, i, id!(Tiles));
                        for (k, slot) in TILE_SLOTS.iter().enumerate() {
                            let view = row.view(cx, slot);
                            let Some(tile) = tiles.get(k) else {
                                view.set_visible(cx, false);
                                continue;
                            };
                            view.set_visible(cx, true);
                            let (icon, name, sub) = match tile {
                                GifTile::Favorites(n) => ("🔥", "Favorites".to_owned(), format!("{n}")),
                                GifTile::Trending => ("📈", "Trending GIFs".to_owned(), "Needs a Tenor key".to_owned()),
                                GifTile::Collection { name, count, .. } => ("📁", name.clone(), format!("{count}")),
                                GifTile::NewCollection => ("➕", "New collection".to_owned(), String::new()),
                            };
                            row.label(cx, &[slot[0], id!(icon)]).set_text(cx, icon);
                            row.label(cx, &[slot[0], id!(name)]).set_text(cx, &name);
                            row.label(cx, &[slot[0], id!(sub)]).set_text(cx, &sub);
                        }
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    Some(Row::Gifs(gifs)) => {
                        let row = list.item(cx, i, id!(Gifs));
                        for (k, slot) in TILE_SLOTS.iter().enumerate() {
                            let view = row.view(cx, slot);
                            let Some((gif, fav)) = gifs.get(k) else {
                                view.set_visible(cx, false);
                                continue;
                            };
                            view.set_visible(cx, true);
                            let img = row.image(cx, &[slot[0], id!(img)]);
                            let preview = if gif.preview.is_empty() { &gif.url } else { &gif.preview };
                            crate::images::show(cx, &img, Some(preview));
                            // Rails' fire button: lit when it's a favorite.
                            let mut fire = row.widget(cx, &[slot[0], id!(fire), id!(glyph)]);
                            let a = if *fav { 1.0 } else { 0.35 };
                            script_apply_eval!(cx, fire, {draw_text +: {color: #(vec4(1.0, 1.0, 1.0, a))}});
                        }
                        row.draw_all(cx, &mut Scope::empty());
                    }
                    Some(Row::Empty(t)) => {
                        let row = list.item(cx, i, id!(Empty));
                        row.set_text(cx, t);
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
