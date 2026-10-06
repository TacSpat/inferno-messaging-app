//! Spike 2a: the Rails shell in Makepad, with a 10,000-message list.
//! Layout and sizes follow the spec's visual section and the Rails views
//! (`layouts/application.html.erb`, `shared/_server_rail`, `channels/_channel_item`,
//! `messages/_message`, `channels/show`, `servers/_member_sidebar`).

pub use makepad_widgets;

mod demo;
mod message_list;
#[allow(dead_code)] // the other six themes land with runtime switching
mod theme;

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

    startup() do #(App::script_component(vm)){
        ui: Root{
            main_window := Window{
                window.title: "Inferno"
                window.inner_size: vec2(1400, 860)
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
                            RailSlot{
                                View{width: 72 height: 48 align: Align{x: 0.0 y: 0.5}
                                    // Active pill: 3×40 accent-light at the left edge.
                                    RoundedView{width: 3 height: 40 draw_bg.color: accent_light draw_bg.border_radius: 1.5}
                                }
                                RailIcon{
                                    draw_bg.color: accent
                                    draw_bg.color_2: accent_dark
                                    draw_bg.border_radius: 12.0
                                    initials.text: "TI"
                                }
                            }
                            RailSlot{RailIcon{initials.text: "NS"}}
                            RailSlot{RailIcon{initials.text: "RD"}}
                            RailSlot{RailIcon{initials.text: "GA"}}
                            RailSlot{
                                RoundedView{width: 48 height: 48 align: Center
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
                                Txt{width: Fill text: "Tac's Inferno" draw_text.color: #xffffff
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

                            ScrollYView{
                                width: Fill height: Fill
                                flow: Down spacing: 2
                                padding: Inset{left: 8 right: 8 top: 8 bottom: 8}
                                CategoryHeader{label.text: "TEXT CHANNELS"}
                                // Active: gray-600 fill with a 2px accent left border.
                                RoundedView{
                                    width: Fill height: Fit
                                    flow: Overlay
                                    draw_bg.color: gray_600
                                    draw_bg.border_radius: 4.0
                                    new_batch: true
                                    ChannelItem{hash.draw_text.color: #xe1e0df99 name.text: "general" name.draw_text.color: #xffffff}
                                    RoundedView{width: 2 height: 33 draw_bg.color: accent draw_bg.border_radius: 1.0}
                                }
                                ChannelItem{name.text: "announcements"}
                                ChannelItem{name.text: "dev-chat" name.draw_text.color: #xffffff
                                    name.draw_text.text_style: theme.font_bold{font_size: 10.5}}
                                ChannelItem{name.text: "screenshots"}
                                ChannelItem{name.text: "off-topic"}
                                CategoryHeader{label.text: "VOICE CHANNELS"}
                                ChannelItem{hash.text: "🔊" name.text: "Lounge"}
                                ChannelItem{hash.text: "🔊" name.text: "Gaming"}
                                CategoryHeader{label.text: "PRIVATE"}
                                ChannelItem{hash.text: "🔒" name.text: "mods"}
                            }

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
                                    Txt{text: "T" draw_text.text_style.font_size: 10.0}}
                                View{width: Fill height: Fit flow: Down
                                    Txt{text: "Tac" draw_text.color: #xffffff}
                                    Txt{text: "🔥 Online" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
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
                                Txt{text: "#" draw_text.color: gray_400 draw_text.text_style.font_size: 15.0}
                                Txt{text: "general" draw_text.color: #xffffff
                                    draw_text.text_style: theme.font_bold{font_size: 12.0}}
                                SolidView{width: 1 height: 24 margin: Inset{left: 8 right: 8} draw_bg.color: gray_600}
                                Txt{width: Fill text: "Hang out, share builds, report bugs" draw_text.color: gray_400}
                                Ico{draw_icon.svg: crate_resource("self:resources/icons/pin.svg")}
                                Ico{draw_icon.svg: crate_resource("self:resources/icons/users.svg")}
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
                            View{width: Fill height: 24 padding: Inset{left: 16}}
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
                            RoleHeader{text: "ADMIN — 1" draw_text.color: #xdc2626}
                            MemberItem{face.avatar.draw_bg.color: #x7f1d1d face.avatar.initial.text: "T"
                                name.text: "Tac" name.draw_text.color: #xdc2626}
                            RoleHeader{text: "ONLINE — 3"}
                            MemberItem{face.avatar.draw_bg.color: #x78350f face.avatar.initial.text: "E" name.text: "ember"}
                            MemberItem{face.avatar.draw_bg.color: #x1e3a8a face.avatar.initial.text: "F" name.text: "frostbyte"}
                            MemberItem{face.avatar.draw_bg.color: #x064e3b face.avatar.initial.text: "M" name.text: "moss"}
                            RoleHeader{text: "OFFLINE — 2"}
                            // Offline members at 40% opacity.
                            MemberItem{face.avatar.draw_bg.color: #x1e1c1b66 face.avatar.initial.text: "N"
                                name.text: "nightjar" name.draw_text.color: #xa8a7a566 face.badge.dot.draw_bg.color: #x656361}
                            MemberItem{face.avatar.draw_bg.color: #x581c8766 face.avatar.initial.text: "Q"
                                name.text: "quill" name.draw_text.color: #xa8a7a566 face.badge.dot.draw_bg.color: #x656361}
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
}

impl MatchEvent for App {
    fn handle_actions(&mut self, cx: &mut Cx, actions: &Actions) {
        let composer = self.ui.text_input(cx, ids!(composer));
        if let Some((text, _)) = composer.returned(actions) {
            if !text.trim().is_empty() {
                if let Some(mut list) = self.ui.widget(cx, ids!(messages)).borrow_mut::<message_list::MessageList>() {
                    list.push_own(cx, text.trim());
                }
                composer.set_text(cx, "");
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
        self.match_event(cx, event);
        self.ui.handle_event(cx, event, &mut Scope::empty());
    }
}
