//! Spike 2a: the Rails shell in Makepad, with a 10,000-message list.
//! Layout and sizes follow the spec's visual section and the Rails views
//! (`layouts/application.html.erb`, `shared/_server_rail`, `channels/_channel_item`,
//! `messages/_message`, `channels/show`, `servers/_member_sidebar`).

pub use makepad_widgets;

mod backend;
mod demo;
mod lists;
mod message_list;
#[allow(dead_code)] // the other six themes land with runtime switching
mod theme;
mod window_state;

use makepad_widgets::*;

app_main!(App);

script_mod! {
    use mod.prelude.widgets.*
    use mod.widgets.*

    // inferno theme tokens (theme.rs holds all seven).
    let gray_950 = #x0a0a09
    let gray_900 = #x141312
    let gray_800 = #x1e1c1b
    let gray_700 = #x2c2a29
    let gray_600 = #x403e3c
    let gray_500 = #x656361
    let gray_400 = #x878583
    let gray_300 = #xa8a7a5
    let gray_200 = #xcccbca
    let gray_100 = #xe1e0df
    let accent = #xdc2626
    let accent_light = #xf87171
    let accent_dark = #xb91c1c

    let Txt = Label{
        draw_text.color: gray_100
        draw_text.text_style.font_size: 10.5
    }

    let Ico = Icon{
        icon_walk: Walk{width: 20 height: 20}
        draw_icon.color: gray_400
    }

    // ─── Server rail ─────────────────────────────────────────────────
    // 72px, gray-950, 12px vertical padding, 8px gaps, 48px icons with a
    // 16px radius (12 when active), active icon filled accent-dark → accent.
    let RailIcon = RoundedView{
        width: 48 height: 48
        align: Center
        new_batch: true
        draw_bg.color: gray_700
        draw_bg.border_radius: 16.0
        initials := Txt{text: "?" draw_text.text_style.font_size: 10.5}
    }

    let RailSlot = View{
        width: 72 height: 48
        flow: Overlay
        align: Align{x: 0.5 y: 0.5}
    }

    // ─── Channel sidebar ─────────────────────────────────────────────
    let ChannelItem = RoundedView{
        width: Fill height: Fit
        padding: Inset{left: 8 right: 8 top: 6 bottom: 6}
        flow: Right spacing: 6
        align: Align{y: 0.5}
        new_batch: true
        draw_bg.color: #0000
        draw_bg.border_radius: 4.0
        hash := Txt{text: "#" draw_text.color: #x87858399 draw_text.text_style.font_size: 12.5}
        name := Txt{text: "channel" draw_text.color: gray_400 draw_text.text_style.font_size: 10.5}
    }

    let CategoryHeader = View{
        width: Fill height: Fit
        padding: Inset{left: 8 right: 8 top: 16 bottom: 4}
        flow: Right spacing: 2
        align: Align{y: 0.5}
        Ico{icon_walk: Walk{width: 12 height: 12} draw_icon.svg: crate_resource("self:resources/icons/chevron_down.svg")}
        label := Txt{text: "CATEGORY" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
    }

    // ─── Member list ─────────────────────────────────────────────────
    let MemberItem = RoundedView{
        width: Fill height: Fit
        padding: Inset{left: 8 right: 8 top: 4 bottom: 4}
        flow: Right spacing: 12
        align: Align{y: 0.5}
        new_batch: true
        draw_bg.color: #0000
        draw_bg.border_radius: 4.0
        face := View{
            width: 32 height: 32
            flow: Overlay
            avatar := RoundedView{
                width: 32 height: 32 align: Center new_batch: true
                draw_bg.color: #x1e1c1b
                draw_bg.border_radius: 16.0
                initial := Txt{text: "?" draw_text.text_style.font_size: 9.5}
            }
            badge := View{width: 32 height: 32 align: Align{x: 1.0 y: 1.0}
                dot := RoundedView{width: 12 height: 12
                    draw_bg.color: #x22c55e
                    draw_bg.border_radius: 6.0
                    draw_bg.border_size: 2.0
                    draw_bg.border_color: gray_800
                }
            }
        }
        name := Txt{text: "member" draw_text.color: gray_300 draw_text.text_style.font_size: 10.5}
    }

    let RoleHeader = Txt{
        width: Fill
        padding: Inset{left: 8 right: 8 top: 16 bottom: 4}
        draw_text.color: gray_400
        draw_text.text_style.font_size: 9.0
    }

    // ─── Message rows ────────────────────────────────────────────────
    // Row: padding 2×8, radius 4. Hover: accent/.06 fill and a 2px accent/.4
    // left border over 0.15s (spec: "Every transition takes 0.15s").
    let MsgRow = RoundedView{
        width: Fill height: Fit
        margin: Inset{left: 16 right: 16 top: 1 bottom: 1}
        padding: Inset{left: 8 right: 8 top: 2 bottom: 2}
        flow: Right
        new_batch: true
        draw_bg +: {
            hover: instance(0.0)
            pixel: fn() {
                let sdf = Sdf2d.viewport(self.pos * self.rect_size)
                sdf.box(0. 0. self.rect_size.x self.rect_size.y 4.0)
                sdf.fill(mix(#xdc262600, #xdc26260f, self.hover))
                sdf.rect(0. 0. 2. self.rect_size.y)
                sdf.fill(mix(#xdc262600, #xdc262666, self.hover))
                return sdf.result
            }
        }
        animator: Animator{
            hover: {
                default: @off
                off: AnimatorState{
                    from: {all: Forward {duration: 0.15}}
                    apply: {draw_bg: {hover: 0.0}}
                }
                on: AnimatorState{
                    from: {all: Forward {duration: 0.15}}
                    apply: {draw_bg: {hover: 1.0}}
                }
            }
        }
    }

    let Body = Txt{
        width: Fill
        draw_text.color: gray_200
        draw_text.text_style.font_size: 10.5
        draw_text.text_style.line_spacing: 1.4
    }

    mod.widgets.MessageListBase = #(message_list::MessageList::register_widget(vm))
    mod.widgets.MessageList = set_type_default() do mod.widgets.MessageListBase{
        width: Fill height: Fill
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            // Follow the newest message while at the bottom; scrolling up
            // stops following, scrolling back down resumes.
            auto_tail: true
            // Spec: the list has 16px padding and 2px gaps. PortalList's own
            // padding throws off its tail-follow math, so the rows carry it
            // as margin instead.

            // A full row: 40px avatar column (16px right margin) + content.
            MsgFull := MsgRow{
                avatar := RoundedView{
                    width: 40 height: 40
                    margin: Inset{right: 16 top: 2}
                    align: Center
                    new_batch: true
                    draw_bg.color: #x1e1c1b
                    draw_bg.border_radius: 20.0
                    initial := Txt{text: "?" draw_text.text_style.font_size: 10.5}
                }
                content := View{
                    width: Fill height: Fit
                    flow: Down spacing: 2
                    reply := Txt{text: "" width: Fill draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                    head := View{
                        width: Fill height: Fit
                        flow: Right spacing: 8
                        align: Align{y: 0.5}
                        name := Txt{text: "name" draw_text.text_style.font_size: 10.5}
                        time := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 9.0}
                    }
                    body := Body{text: ""}
                }
            }

            // Grouped: a 40px spacer replaces the avatar.
            MsgGrouped := MsgRow{
                View{width: 40 height: 1 margin: Inset{right: 16}}
                body := Body{text: ""}
            }

            // System lines: green arrow, gray-300 text, timestamp.
            MsgSystem := View{
                width: Fill height: Fit
                margin: Inset{left: 16 right: 16 top: 1 bottom: 1}
                padding: Inset{left: 8 right: 8 top: 4 bottom: 4}
                flow: Right spacing: 8
                align: Align{y: 0.5}
                Txt{text: "→" draw_text.color: #x4ade80 draw_text.text_style.font_size: 10.5}
                body := Txt{text: "" draw_text.color: gray_300 draw_text.text_style.font_size: 10.5}
                time := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 9.0}
            }
        }
    }

    // ─── Live lists (lists.rs) ───────────────────────────────────────
    mod.widgets.RailListBase = #(lists::RailList::register_widget(vm))
    mod.widgets.RailList = set_type_default() do mod.widgets.RailListBase{
        width: 72 height: Fill
        list := PortalList{
            width: 72 height: Fill
            flow: Down
            Idle := RailSlot{
                margin: Inset{bottom: 8}
                cursor: MouseCursor.Hand
                icon := RailIcon{}
            }
            Active := RailSlot{
                margin: Inset{bottom: 8}
                cursor: MouseCursor.Hand
                View{width: 72 height: 48 align: Align{x: 0.0 y: 0.5}
                    // Active pill: 3×40 accent-light at the left edge.
                    RoundedView{width: 3 height: 40 draw_bg.color: accent_light draw_bg.border_radius: 1.5}
                }
                icon := RailIcon{
                    draw_bg.color: accent
                    draw_bg.color_2: accent_dark
                    draw_bg.border_radius: 12.0
                }
            }
        }
    }

    mod.widgets.ChannelListBase = #(lists::ChannelList::register_widget(vm))
    mod.widgets.ChannelList = set_type_default() do mod.widgets.ChannelListBase{
        width: Fill height: Fill
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Category := CategoryHeader{margin: Inset{left: 8 right: 8}}
            Channel := View{
                width: Fill height: Fit
                margin: Inset{left: 8 right: 8 top: 1 bottom: 1}
                cursor: MouseCursor.Hand
                item := ChannelItem{}
            }
            // Active: gray-600 fill with a 2px accent left border.
            ActiveChannel := RoundedView{
                width: Fill height: Fit
                margin: Inset{left: 8 right: 8 top: 1 bottom: 1}
                flow: Overlay
                cursor: MouseCursor.Hand
                new_batch: true
                draw_bg.color: gray_600
                draw_bg.border_radius: 4.0
                item := ChannelItem{hash.draw_text.color: #xe1e0df99 name.draw_text.color: #xffffff}
                RoundedView{width: 2 height: 33 draw_bg.color: accent draw_bg.border_radius: 1.0}
            }
        }
    }

    mod.widgets.MemberListBase = #(lists::MemberList::register_widget(vm))
    mod.widgets.MemberList = set_type_default() do mod.widgets.MemberListBase{
        width: Fill height: Fill
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Header := RoleHeader{text: ""}
            Member := MemberItem{}
        }
    }

    startup() do #(App::script_component(vm)){
        ui: Root{
            main_window := Window{
                window.title: "Inferno"
                pass.clear_color: gray_700
                body +: {
                    SolidView{
                        width: Fill height: Fill
                        flow: Right
                        draw_bg.color: gray_700

                        // ── Server rail ──
                        SolidView{
                            width: 72 height: Fill
                            flow: Down spacing: 8
                            padding: Inset{top: 12 bottom: 12}
                            align: Align{x: 0.5}
                            draw_bg.color: gray_950
                            RailSlot{
                                RoundedView{width: 48 height: 48 align: Center
                                    draw_bg.color: gray_700
                                    draw_bg.border_radius: 16.0
                                    Ico{icon_walk: Walk{width: 24 height: 24} draw_icon.color: gray_300
                                        draw_icon.svg: crate_resource("self:resources/icons/home.svg")}
                                }
                            }
                            SolidView{width: 32 height: 2 draw_bg.color: gray_800}
                            rail := mod.widgets.RailList{}
                            RailSlot{
                                add_server := RoundedView{width: 48 height: 48 align: Center
                                    cursor: MouseCursor.Hand
                                    draw_bg.color: gray_700
                                    draw_bg.border_radius: 16.0
                                    Ico{icon_walk: Walk{width: 24 height: 24} draw_icon.color: #x22c55e
                                        draw_icon.svg: crate_resource("self:resources/icons/plus.svg")}
                                }
                            }
                        }

                        // ── Channel sidebar ──
                        SolidView{
                            width: 240 height: Fill
                            flow: Down
                            draw_bg.color: gray_800

                            // Header: 48px, server name 16px semibold white, chevron.
                            View{
                                width: Fill height: 48
                                padding: Inset{left: 16 right: 16}
                                flow: Right
                                align: Align{y: 0.5}
                                server_name := Txt{width: Fill text: "" draw_text.color: #xffffff
                                    draw_text.text_style: theme.font_bold{font_size: 12.0}}
                                Ico{icon_walk: Walk{width: 16 height: 16}
                                    draw_icon.svg: crate_resource("self:resources/icons/chevron_down.svg")}
                            }
                            // The "lava seam": a gradient line under the header.
                            RoundedView{width: Fill height: 1
                                draw_bg.color: accent_dark
                                draw_bg.color_2: #x1e1c1b
                                draw_bg.gradient_fill_horizontal: 1.0
                                draw_bg.border_radius: 0.0
                            }

                            channels := mod.widgets.ChannelList{margin: Inset{top: 8}}

                            // User panel: gray-950, 8px padding, 32px avatar,
                            // name 14 medium, status 12 gray-400, version 10 gray-600.
                            SolidView{
                                width: Fill height: Fit
                                padding: Inset{left: 8 right: 8 top: 8 bottom: 8}
                                flow: Right spacing: 8
                                align: Align{y: 0.5}
                                new_batch: true
                                draw_bg.color: gray_950
                                RoundedView{width: 32 height: 32 align: Center new_batch: true
                                    draw_bg.color: #x7f1d1d draw_bg.border_radius: 16.0
                                    me_initial := Txt{text: "" draw_text.text_style.font_size: 10.0}}
                                profile_btn := View{width: Fill height: Fit flow: Down cursor: MouseCursor.Hand
                                    name := Txt{text: "" draw_text.color: #xffffff}
                                    status := Txt{text: "Connecting…" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                                }
                                Txt{text: "v0.1.0" draw_text.color: gray_600 draw_text.text_style.font_size: 7.5}
                                Ico{icon_walk: Walk{width: 16 height: 16}
                                    draw_icon.svg: crate_resource("self:resources/icons/gear.svg")}
                            }
                        }

                        // ── Chat column ──
                        View{
                            width: Fill height: Fill
                            flow: Down
                            // Header: 48px, 16px side padding, icon, name, divider, topic.
                            View{
                                width: Fill height: 48
                                padding: Inset{left: 16 right: 16}
                                flow: Right spacing: 8
                                align: Align{y: 0.5}
                                channel_hash := Txt{text: "#" draw_text.color: gray_400 draw_text.text_style.font_size: 15.0}
                                channel_name := Txt{text: "" draw_text.color: #xffffff
                                    draw_text.text_style: theme.font_bold{font_size: 12.0}}
                                SolidView{width: 1 height: 24 margin: Inset{left: 8 right: 8} draw_bg.color: gray_600}
                                // Topics are one line: truncate, don't wrap (Rails: truncate).
                                channel_topic := Txt{width: Fill text: "" draw_text.color: gray_400
                                    flow: Flow.Right{wrap: false} text_overflow: TextOverflow.Ellipsis}
                                Ico{draw_icon.svg: crate_resource("self:resources/icons/pin.svg")}
                                invite_btn := View{width: Fit height: Fit cursor: MouseCursor.Hand
                                    Ico{draw_icon.svg: crate_resource("self:resources/icons/users.svg")}}
                                RoundedView{width: 160 height: 28 padding: Inset{left: 8 right: 8}
                                    align: Align{y: 0.5} new_batch: true
                                    draw_bg.color: gray_900 draw_bg.border_radius: 4.0
                                    Txt{width: Fill text: "Search" draw_text.color: gray_500 draw_text.text_style.font_size: 9.5}
                                    Ico{icon_walk: Walk{width: 14 height: 14}
                                        draw_icon.svg: crate_resource("self:resources/icons/search.svg")}
                                }
                            }
                            SolidView{width: Fill height: 1 draw_bg.color: #xdc26261f}

                            messages := mod.widgets.MessageList{}

                            // Typing row (24px) then the composer.
                            View{width: Fill height: 24 padding: Inset{left: 16} align: Align{y: 0.5}
                                notice := Txt{width: Fill text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                            }
                            View{
                                width: Fill height: Fit
                                padding: Inset{left: 16 right: 16 bottom: 16}
                                // Bar: gray-600, radius 8, 1px accent/.2 border.
                                RoundedView{
                                    width: Fill height: Fit
                                    padding: Inset{left: 4 right: 4}
                                    flow: Right
                                    align: Align{y: 0.5}
                                    new_batch: true
                                    draw_bg.color: gray_600
                                    draw_bg.border_radius: 8.0
                                    draw_bg.border_size: 1.0
                                    draw_bg.border_color: #xdc262633
                                    View{width: Fit height: Fit padding: 8
                                        Ico{draw_icon.svg: crate_resource("self:resources/icons/plus.svg")}}
                                    composer := TextInput{
                                        width: Fill height: 40
                                        empty_text: "Message #general"
                                        draw_bg +: {color: #0000 color_hover: #0000 color_focus: #0000 color_empty: #0000
                                            border_color: #0000 border_color_hover: #0000 border_color_focus: #0000 border_color_empty: #0000}
                                        draw_text +: {color: gray_100 color_empty: gray_400}
                                    }
                                    View{width: Fit height: Fit padding: 8
                                        Ico{draw_icon.svg: crate_resource("self:resources/icons/eye_off.svg")}}
                                    View{width: Fit height: Fit padding: 8
                                        Ico{draw_icon.svg: crate_resource("self:resources/icons/smile.svg")}}
                                    View{width: Fit height: Fit padding: 8
                                        Ico{draw_icon.svg: crate_resource("self:resources/icons/send.svg")}}
                                }
                            }
                        }

                        // ── Member list: 240px, gray-800, 1px accent/.15 left border ──
                        SolidView{width: 1 height: Fill draw_bg.color: #xdc262626}
                        SolidView{
                            width: 240 height: Fill
                            flow: Down
                            padding: Inset{left: 8 right: 8 top: 0 bottom: 16}
                            draw_bg.color: gray_800
                            members := mod.widgets.MemberList{}
                        }
                    }

                    // Create or join (opened by the rail's +).
                    dialog := Modal{
                        content +: {
                            RoundedView{
                                width: 448 height: Fit
                                flow: Down spacing: 10
                                padding: 24
                                new_batch: true
                                draw_bg.color: gray_800
                                draw_bg.border_radius: 12.0
                                Txt{text: "Create a server" draw_text.color: #xffffff
                                    draw_text.text_style: theme.font_bold{font_size: 13.0}}
                                new_server_name := TextInput{width: Fill height: 36 empty_text: "Server name"}
                                create_server := Button{text: "Create"}
                                SolidView{width: Fill height: 1 margin: Inset{top: 6 bottom: 6} draw_bg.color: gray_700}
                                Txt{text: "Join with an invite" draw_text.color: #xffffff
                                    draw_text.text_style: theme.font_bold{font_size: 13.0}}
                                invite_link := TextInput{width: Fill height: 36 empty_text: "nostr:naddr1…"}
                                join_server := Button{text: "Join"}
                            }
                        }
                    }
                }
            }
        }
    }
}

#[derive(Script, ScriptHook)]
pub struct App {
    #[live]
    ui: WidgetRef,
    /// Where we asked the window to be, to learn the decoration offset.
    #[rust]
    requested_pos: Option<DVec2>,
    /// The OS reports the inner position but places by the frame; subtract
    /// the difference when saving or the window creeps down every launch.
    #[rust]
    frame_offset: Option<DVec2>,
    #[rust]
    backend: Option<tokio::sync::mpsc::UnboundedSender<backend::Command>>,
    /// (gid, channel) the message list is showing, to tell a new channel
    /// (jump to newest) from new messages in the same one (keep scroll).
    #[rust]
    showing: Option<(String, String)>,
    #[rust]
    npub: String,
}

impl App {
    fn send(&self, cmd: backend::Command) {
        if let Some(tx) = &self.backend {
            let _ = tx.send(cmd);
        }
    }

    fn notice(&self, cx: &mut Cx, text: &str) {
        self.ui.label(cx, ids!(notice)).set_text(cx, text);
    }

    fn apply(&mut self, cx: &mut Cx, update: &backend::Update) {
        use backend::Update;
        match update {
            Update::Ready { name, npub, backed_up } => {
                self.npub = npub.clone();
                self.ui.label(cx, ids!(profile_btn.name)).set_text(cx, name);
                self.ui.label(cx, ids!(me_initial)).set_text(cx, &name.chars().nth(5).unwrap_or('?').to_uppercase().to_string());
                let status = if *backed_up { "Online" } else { "Online · key not backed up" };
                self.ui.label(cx, ids!(profile_btn.status)).set_text(cx, status);
            }
            Update::Servers(servers) => {
                if let Some(mut rail) = self.ui.widget(cx, ids!(rail)).borrow_mut::<lists::RailList>() {
                    rail.servers = servers.clone();
                }
                self.ui.widget(cx, ids!(rail)).redraw(cx);
            }
            Update::Server { gid, name, sidebar, members } => {
                if let Some(mut rail) = self.ui.widget(cx, ids!(rail)).borrow_mut::<lists::RailList>() {
                    rail.selected = Some(gid.clone());
                }
                self.ui.widget(cx, ids!(rail)).redraw(cx);
                self.ui.label(cx, ids!(server_name)).set_text(cx, name);
                if self.ui.label(cx, ids!(notice)).text().starts_with("Joining") {
                    self.notice(cx, "");
                }
                if let Some(mut list) = self.ui.widget(cx, ids!(channels)).borrow_mut::<lists::ChannelList>() {
                    list.rows = sidebar.clone();
                }
                self.ui.widget(cx, ids!(channels)).redraw(cx);
                if let Some(mut list) = self.ui.widget(cx, ids!(members)).borrow_mut::<lists::MemberList>() {
                    list.rows = members.clone();
                }
                self.ui.widget(cx, ids!(members)).redraw(cx);
            }
            Update::Channel { gid, channel_id, name, topic, encrypted } => {
                if let Some(mut list) = self.ui.widget(cx, ids!(channels)).borrow_mut::<lists::ChannelList>() {
                    list.selected = Some(channel_id.clone());
                }
                self.ui.widget(cx, ids!(channels)).redraw(cx);
                self.ui.label(cx, ids!(channel_hash)).set_text(cx, if *encrypted { "🔒" } else { "#" });
                self.ui.label(cx, ids!(channel_name)).set_text(cx, name);
                self.ui.label(cx, ids!(channel_topic)).set_text(cx, topic);
                let _ = gid;
            }
            Update::Timeline { gid, channel_id, rows } => {
                let key = (gid.clone(), channel_id.clone());
                let new_channel = self.showing.as_ref() != Some(&key);
                self.showing = Some(key);
                if let Some(mut list) = self.ui.widget(cx, ids!(messages)).borrow_mut::<message_list::MessageList>() {
                    list.set_rows(cx, rows.clone(), new_channel);
                }
            }
            Update::Invite(link) => {
                cx.copy_to_clipboard(link);
                self.notice(cx, &format!("Invite link copied: {link}"));
            }
            Update::Error(e) => self.notice(cx, &format!("⚠ {e}")),
            Update::Empty => {
                self.ui.label(cx, ids!(server_name)).set_text(cx, "No servers yet");
                self.ui.label(cx, ids!(channel_name)).set_text(cx, "Welcome");
                self.ui.label(cx, ids!(channel_topic)).set_text(cx, "Create or join a server with + in the rail");
            }
        }
    }
}

impl MatchEvent for App {
    fn handle_startup(&mut self, cx: &mut Cx) {
        let w = window_state::load();
        self.requested_pos = Some(dvec2(w.x, w.y));
        self.ui.window(cx, ids!(main_window)).configure_window(
            cx,
            dvec2(w.width, w.height),
            dvec2(w.x, w.y),
            w.maximized,
            "Inferno".into(),
        );
        if std::env::var_os("INFERNO_DEMO").is_some() {
            if let Some(mut list) = self.ui.widget(cx, ids!(messages)).borrow_mut::<message_list::MessageList>() {
                list.set_rows(cx, message_list::demo_rows(), true);
            }
        } else {
            self.backend = Some(backend::spawn());
        }
    }

    fn handle_actions(&mut self, cx: &mut Cx, actions: &Actions) {
        for action in actions {
            if let Some(update) = action.downcast_ref::<backend::Update>() {
                self.apply(cx, update);
            }
        }

        let rail_click = self.ui.widget(cx, ids!(rail)).borrow::<lists::RailList>().and_then(|r| r.clicked(cx, actions));
        if let Some(gid) = rail_click {
            self.send(backend::Command::SelectServer(gid));
        }
        let channel_click =
            self.ui.widget(cx, ids!(channels)).borrow::<lists::ChannelList>().and_then(|c| c.clicked(cx, actions));
        if let Some(id) = channel_click {
            self.send(backend::Command::SelectChannel(id));
        }

        if self.ui.view(cx, ids!(add_server)).finger_up(actions).is_some_and(|e| !e.cancelled) {
            self.ui.modal(cx, ids!(dialog)).open(cx);
        }
        if self.ui.view(cx, ids!(profile_btn)).finger_up(actions).is_some_and(|e| !e.cancelled) && !self.npub.is_empty() {
            cx.copy_to_clipboard(&self.npub);
            self.notice(cx, &format!("Your npub was copied: {}", self.npub));
        }
        if self.ui.view(cx, ids!(invite_btn)).finger_up(actions).is_some_and(|e| !e.cancelled) {
            self.send(backend::Command::CreateInvite);
        }
        if self.ui.button(cx, ids!(create_server)).clicked(actions) {
            let name = self.ui.text_input(cx, ids!(new_server_name)).text();
            if !name.trim().is_empty() {
                self.send(backend::Command::CreateServer(name));
                self.ui.text_input(cx, ids!(new_server_name)).set_text(cx, "");
                self.ui.modal(cx, ids!(dialog)).close(cx);
            }
        }
        if self.ui.button(cx, ids!(join_server)).clicked(actions) {
            let link = self.ui.text_input(cx, ids!(invite_link)).text();
            if !link.trim().is_empty() {
                self.send(backend::Command::Join(link));
                self.ui.text_input(cx, ids!(invite_link)).set_text(cx, "");
                self.ui.modal(cx, ids!(dialog)).close(cx);
                self.notice(cx, "Joining…");
            }
        }

        let composer = self.ui.text_input(cx, ids!(composer));
        if let Some((text, _)) = composer.returned(actions) {
            let text = text.trim();
            if !text.is_empty() {
                self.send(backend::Command::Send(text.to_owned()));
                if let Some(mut list) = self.ui.widget(cx, ids!(messages)).borrow_mut::<message_list::MessageList>() {
                    list.follow_end(cx);
                }
                composer.set_text(cx, "");
                // A single-line input drops focus on Return; keep typing in
                // the chat like Rails and Discord do.
                if let Some(mut input) = composer.borrow_mut() {
                    input.take_key_focus(cx);
                }
                self.notice(cx, "");
            }
        }
    }
}

impl AppMain for App {
    fn script_mod(vm: &mut ScriptVm) -> ScriptValue {
        crate::makepad_widgets::script_mod(vm);
        self::script_mod(vm)
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event) {
        if let Event::WindowGeomChange(e) = event {
            let g = &e.new_geom;
            let offset = *self.frame_offset.get_or_insert_with(|| {
                let d = self.requested_pos.map_or(dvec2(0.0, 0.0), |r| g.position - r);
                // Only a title bar's worth; anything bigger is the WM moving us.
                if d.x.abs() < 80.0 && d.y.abs() < 80.0 { d } else { dvec2(0.0, 0.0) }
            });
            window_state::save(&window_state::WindowState {
                x: g.position.x - offset.x,
                y: g.position.y - offset.y,
                width: g.inner_size.x,
                height: g.inner_size.y,
                maximized: g.is_fullscreen,
            });
        }
        self.match_event(cx, event);
        self.ui.handle_event(cx, event, &mut Scope::empty());
    }
}
