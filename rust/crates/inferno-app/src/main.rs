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
            // 0..1: jump-to flash, accent/.3 at full strength.
            flash: instance(0.0)
            pixel: fn() {
                let sdf = Sdf2d.viewport(self.pos * self.rect_size)
                sdf.box(0. 0. self.rect_size.x self.rect_size.y 4.0)
                let fill = mix(#xdc262600, #xdc26260f, self.hover)
                sdf.fill(mix(fill, #xdc26264d, self.flash))
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

    // Hover toolbar: gray-800, radius 4, 1px accent/.25 border (spec).
    let ToolBtn = View{
        width: Fit height: Fit
        padding: 6
        cursor: MouseCursor.Hand
    }
    let Toolbar = RoundedView{
        width: Fit height: Fit
        flow: Right
        new_batch: true
        draw_bg.color: gray_800
        draw_bg.border_radius: 4.0
        draw_bg.border_size: 1.0
        draw_bg.border_color: #xdc262640
        reply_btn := ToolBtn{Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/reply.svg")}}
        pin_btn := ToolBtn{Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/pin.svg")}}
        edit_btn := ToolBtn{Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/edit.svg")}}
    }
    // Floats at the row's top right (Rails: top-0 right-2).
    let ToolbarSlot = View{
        width: Fill height: Fit
        align: Align{x: 1.0 y: 0.0}
        padding: Inset{right: 8}
        toolbar := Toolbar{}
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

            // A full row: 40px avatar column (16px right margin) + content,
            // with the hover toolbar laid over it inside the same row, so
            // moving onto the toolbar doesn't leave the row's hover.
            MsgFull := MsgRow{
                flow: Overlay
                line := View{
                    width: Fill height: Fit
                    flow: Right
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
                        // Reply preview: click to jump to the parent.
                        reply := View{width: Fill height: Fit cursor: MouseCursor.Hand
                            text := Txt{text: "" width: Fill draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                        }
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
                slot := ToolbarSlot{}
            }

            // Grouped: a 40px spacer replaces the avatar.
            MsgGrouped := MsgRow{
                flow: Overlay
                line := View{
                    width: Fill height: Fit
                    flow: Right
                    View{width: 40 height: 1 margin: Inset{right: 16}}
                    body := Body{text: ""}
                }
                slot := ToolbarSlot{}
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

    mod.widgets.PinsListBase = #(lists::PinsList::register_widget(vm))
    mod.widgets.PinsList = set_type_default() do mod.widgets.PinsListBase{
        width: Fill height: 320
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Pin := RoundedView{
                width: Fill height: Fit
                margin: Inset{bottom: 6}
                padding: Inset{left: 10 right: 10 top: 8 bottom: 8}
                flow: Down spacing: 2
                cursor: MouseCursor.Hand
                new_batch: true
                draw_bg.color: gray_800
                draw_bg.border_radius: 6.0
                author := Txt{text: "" draw_text.color: #xffffff draw_text.text_style.font_size: 9.5}
                body := Txt{width: Fill text: "" draw_text.color: gray_200}
            }
            Empty := Txt{text: "No pinned messages yet." draw_text.color: gray_500 margin: 8}
        }
    }

    // Reply / edit bars above the composer: gray-700, rounded top.
    let ComposerBar = RoundedView{
        visible: false
        width: Fill height: Fit
        padding: Inset{left: 16 right: 8 top: 6 bottom: 6}
        flow: Right spacing: 6
        align: Align{y: 0.5}
        new_batch: true
        draw_bg.color: gray_700
        draw_bg.border_radius: 8.0
        label := Txt{width: Fill text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 9.5}
        close := ToolBtn{Ico{icon_walk: Walk{width: 14 height: 14} draw_icon.svg: crate_resource("self:resources/icons/close.svg")}}
    }

    // ─── Settings overlay ────────────────────────────────────────────
    let NavHeader = Txt{
        margin: Inset{left: 8 top: 16 bottom: 6}
        draw_text.color: gray_400
        draw_text.text_style: theme.font_bold{font_size: 8.5}
    }
    let NavItem = RoundedView{
        width: Fill height: Fit
        padding: Inset{left: 8 right: 8 top: 6 bottom: 6}
        cursor: MouseCursor.Hand
        new_batch: true
        draw_bg.color: #0000
        draw_bg.border_radius: 4.0
        label := Txt{text: "" draw_text.color: gray_400}
    }
    let FieldLabel = Txt{
        margin: Inset{top: 16 bottom: 6}
        draw_text.color: gray_500
        draw_text.text_style: theme.font_bold{font_size: 8.0}
    }
    let Field = TextInput{width: Fill height: 36}
    let PageTitle = Txt{
        margin: Inset{bottom: 8}
        draw_text.color: #xffffff
        draw_text.text_style: theme.font_bold{font_size: 15.0}
    }
    let Hint = Txt{width: Fill draw_text.color: gray_400 draw_text.text_style.font_size: 9.5}

    mod.widgets.RelayListBase = #(lists::RelayList::register_widget(vm))
    mod.widgets.RelayList = set_type_default() do mod.widgets.RelayListBase{
        width: Fill height: 300
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Relay := RoundedView{
                width: Fill height: Fit
                margin: Inset{bottom: 6}
                padding: Inset{left: 12 right: 8 top: 8 bottom: 8}
                flow: Right spacing: 12
                align: Align{y: 0.5}
                new_batch: true
                draw_bg.color: gray_800
                draw_bg.border_radius: 6.0
                url := Txt{width: Fill text: "" draw_text.color: gray_200}
                mode := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 9.0}
                remove := View{width: Fit height: Fit padding: 6 cursor: MouseCursor.Hand
                    Txt{text: "Remove" draw_text.color: #xf87171 draw_text.text_style.font_size: 9.0}}
            }
        }
    }

    startup() do #(App::script_component(vm)){
        ui: Root{
            main_window := Window{
                window.title: "Inferno"
                pass.clear_color: gray_700
                body +: {
                    View{width: Fill height: Fill flow: Overlay
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
                                open_settings := View{width: Fit height: Fit padding: 4 cursor: MouseCursor.Hand
                                    Ico{icon_walk: Walk{width: 16 height: 16}
                                        draw_icon.svg: crate_resource("self:resources/icons/gear.svg")}}
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
                                pins_btn := View{width: Fit height: Fit cursor: MouseCursor.Hand
                                    Ico{draw_icon.svg: crate_resource("self:resources/icons/pin.svg")}}
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

                            msg_area := View{
                                width: Fill height: Fill
                                flow: Overlay
                                messages := mod.widgets.MessageList{}
                                // Pinned messages float over the list, under the header.
                                pins_slot := View{
                                    width: Fill height: Fit
                                    align: Align{x: 1.0}
                                    padding: Inset{right: 16 top: 4}
                                    pins_panel := RoundedView{
                                        visible: false
                                        width: 420 height: Fit
                                        flow: Down spacing: 8
                                        padding: 12
                                        new_batch: true
                                        draw_bg.color: gray_900
                                        draw_bg.border_radius: 8.0
                                        draw_bg.border_size: 1.0
                                        draw_bg.border_color: gray_700
                                        Txt{text: "Pinned Messages" draw_text.color: #xffffff
                                            draw_text.text_style: theme.font_bold{font_size: 11.0}}
                                        pins := mod.widgets.PinsList{}
                                    }
                                }
                            }

                            // Typing row (24px) then the composer.
                            View{width: Fill height: 24 padding: Inset{left: 16} align: Align{y: 0.5}
                                notice := Txt{width: Fill text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                            }
                            View{
                                width: Fill height: Fit
                                flow: Down
                                padding: Inset{left: 16 right: 16 bottom: 16}
                                reply_bar := ComposerBar{}
                                edit_bar := ComposerBar{label.text: "Editing message — Enter to save, Esc to cancel" label.draw_text.color: #xf87171}
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

                    // Full-screen settings (spec: 224px gray-800 nav, content
                    // max 768 with 32×40 padding, 36px close circle, Esc).
                    settings := SolidView{
                        visible: false
                        width: Fill height: Fill
                        flow: Right
                        draw_bg.color: gray_900
                        SolidView{
                            width: 224 height: Fill
                            flow: Down spacing: 2
                            padding: Inset{left: 16 right: 16 top: 24}
                            draw_bg.color: gray_800
                            NavHeader{text: "USER SETTINGS"}
                            nav_account := NavItem{label.text: "My Account"}
                            nav_profile := NavItem{label.text: "Profile"}
                            NavHeader{text: "APP SETTINGS"}
                            nav_relays := NavItem{label.text: "Relays"}
                        }
                        ScrollYView{
                            width: Fill height: Fill
                            flow: Down
                            padding: Inset{left: 40 right: 40 top: 32 bottom: 32}

                            page_account := View{
                                width: 768 height: Fit flow: Down
                                PageTitle{text: "My Account"}
                                FieldLabel{text: "PUBLIC KEY (NPUB)"}
                                View{width: Fill height: Fit flow: Right spacing: 12 align: Align{y: 0.5}
                                    account_npub := Txt{width: Fill text: "" draw_text.color: gray_200}
                                    copy_npub := Button{text: "Copy"}
                                }
                                FieldLabel{text: "KEY BACKUP"}
                                backup_status := Hint{text: ""}
                                backup_form := View{width: Fill height: Fit flow: Down spacing: 8 margin: Inset{top: 8}
                                    Hint{text: "Choose a password to encrypt a backup of your key (NIP-49). You'll need it to sign in on another device or switch back to this account."}
                                    backup_pw := Field{is_password: true empty_text: "Backup password (8+ characters)"}
                                    backup_pw2 := Field{is_password: true empty_text: "Confirm password"}
                                    make_backup := Button{text: "Create backup"}
                                }
                            }

                            page_profile := View{
                                visible: false
                                width: 768 height: Fit flow: Down
                                PageTitle{text: "Profile"}
                                FieldLabel{text: "DISPLAY NAME"}
                                p_display := Field{empty_text: "How you appear to others"}
                                FieldLabel{text: "USERNAME"}
                                p_username := Field{empty_text: "username"}
                                FieldLabel{text: "ABOUT ME"}
                                p_about := Field{empty_text: "Tell others about yourself"}
                                FieldLabel{text: "CUSTOM STATUS"}
                                View{width: Fill height: Fit flow: Right spacing: 8
                                    p_status_emoji := TextInput{width: 60 height: 36 empty_text: "🙂"}
                                    p_status := Field{empty_text: "What are you up to?"}
                                }
                                FieldLabel{text: "PROFILE THEME"}
                                View{width: Fill height: Fit flow: Right spacing: 8
                                    p_color := TextInput{width: 140 height: 36 empty_text: "#1e1c1b"}
                                    p_color_2 := TextInput{width: 140 height: 36 empty_text: "#1e1c1b"}
                                }
                                View{width: Fill height: Fit margin: Inset{top: 20} flow: Right spacing: 12 align: Align{y: 0.5}
                                    save_profile := Button{text: "Save Changes"}
                                    profile_note := Hint{text: ""}
                                }
                            }

                            page_relays := View{
                                visible: false
                                width: 768 height: Fit flow: Down
                                PageTitle{text: "Relays"}
                                Hint{text: "Where your messages are published and read. The list is shared with your other devices (NIP-65)."}
                                View{width: Fill height: Fit margin: Inset{top: 16 bottom: 12} flow: Right spacing: 8
                                    new_relay := Field{empty_text: "wss://relay.example.com"}
                                    add_relay := Button{text: "Add"}
                                }
                                relay_list := mod.widgets.RelayList{}
                            }
                        }
                        View{width: Fit height: Fit padding: 24 flow: Down align: Align{x: 0.5} spacing: 4
                            close_settings := RoundedView{
                                width: 36 height: 36
                                align: Center
                                cursor: MouseCursor.Hand
                                draw_bg.color: #0000
                                draw_bg.border_radius: 18.0
                                draw_bg.border_size: 2.0
                                draw_bg.border_color: gray_600
                                Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/close.svg")}
                            }
                            Txt{text: "ESC" draw_text.color: gray_500 draw_text.text_style.font_size: 8.0}
                        }
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
    /// Event id we're replying to.
    #[rust]
    reply_to: Option<String>,
    /// Event id we're editing.
    #[rust]
    editing: Option<String>,
}

const SETTINGS_PAGES: [(&[LiveId], &[LiveId]); 3] = [
    (ids!(nav_account), ids!(page_account)),
    (ids!(nav_profile), ids!(page_profile)),
    (ids!(nav_relays), ids!(page_relays)),
];

impl App {
    fn send(&self, cmd: backend::Command) {
        if let Some(tx) = &self.backend {
            let _ = tx.send(cmd);
        }
    }

    fn focus_composer(&self, cx: &mut Cx) {
        if let Some(mut input) = self.ui.text_input(cx, ids!(composer)).borrow_mut() {
            input.take_key_focus(cx);
        }
    }

    fn clear_bars(&mut self, cx: &mut Cx) {
        self.reply_to = None;
        if self.editing.take().is_some() {
            self.ui.text_input(cx, ids!(composer)).set_text(cx, "");
        }
        self.ui.view(cx, ids!(reply_bar)).set_visible(cx, false);
        self.ui.view(cx, ids!(edit_bar)).set_visible(cx, false);
        self.ui.redraw(cx);
    }

    fn message_action(&mut self, cx: &mut Cx, action: message_list::MessageAction) {
        use message_list::MessageAction;
        let row = self
            .ui
            .widget(cx, ids!(messages))
            .borrow::<message_list::MessageList>()
            .and_then(|l| {
                let i = match action {
                    MessageAction::Reply(i) | MessageAction::Edit(i) | MessageAction::Pin(i) => i,
                };
                l.row(i).cloned()
            });
        let Some(row) = row else { return };
        match action {
            MessageAction::Reply(_) => {
                self.clear_bars(cx);
                self.reply_to = Some(row.id.clone());
                let preview: String = row.body.as_deref().unwrap_or("…").chars().take(80).collect();
                self.ui.label(cx, ids!(reply_bar.label)).set_text(cx, &format!("Replying to {}  —  {}", row.author, preview));
                self.ui.view(cx, ids!(reply_bar)).set_visible(cx, true);
                self.focus_composer(cx);
            }
            MessageAction::Edit(_) => {
                self.clear_bars(cx);
                self.editing = Some(row.id.clone());
                self.ui.text_input(cx, ids!(composer)).set_text(cx, row.body.as_deref().unwrap_or(""));
                self.ui.view(cx, ids!(edit_bar)).set_visible(cx, true);
                self.focus_composer(cx);
            }
            MessageAction::Pin(_) => self.send(backend::Command::Pin { id: row.id.clone(), pinned: !row.pinned }),
        }
        self.ui.redraw(cx);
    }

    fn show_settings_page(&mut self, cx: &mut Cx, page: usize) {
        for (i, (nav, view)) in SETTINGS_PAGES.iter().enumerate() {
            let active = i == page;
            self.ui.view(cx, view).set_visible(cx, active);
            let mut item = self.ui.widget(cx, nav);
            let (bg, fg) = if active {
                (lists::rgba(0x403e3c, 1.0), lists::rgba(0xffffff, 1.0))
            } else {
                (lists::rgba(0x000000, 0.0), lists::rgba(0x878583, 1.0))
            };
            script_apply_eval!(cx, item, {draw_bg +: {color: #(bg)}});
            let mut label = self.ui.widget(cx, &[nav[0], id!(label)]);
            script_apply_eval!(cx, label, {draw_text +: {color: #(fg)}});
        }
        self.ui.redraw(cx);
    }

    fn set_settings_open(&mut self, cx: &mut Cx, open: bool) {
        self.ui.view(cx, ids!(settings)).set_visible(cx, open);
        if open {
            self.show_settings_page(cx, 0);
        }
        self.ui.redraw(cx);
    }

    fn notice(&self, cx: &mut Cx, text: &str) {
        self.ui.label(cx, ids!(notice)).set_text(cx, text);
    }

    fn apply(&mut self, cx: &mut Cx, update: &backend::Update) {
        use backend::Update;
        match update {
            Update::Ready { name, npub, backed_up } => {
                self.npub = npub.clone();
                self.ui.label(cx, ids!(account_npub)).set_text(cx, npub);
                self.ui.label(cx, ids!(backup_status)).set_text(
                    cx,
                    if *backed_up { "✓ Your key is backed up." } else { "⚠ Your key isn't backed up yet. If this device is lost, so is your account." },
                );
                self.ui.view(cx, ids!(backup_form)).set_visible(cx, !*backed_up);
                self.ui.label(cx, ids!(profile_btn.name)).set_text(cx, name);
                self.ui.label(cx, ids!(me_initial)).set_text(cx, &name.chars().nth(5).unwrap_or('?').to_uppercase().to_string());
                let status = if *backed_up { "Online" } else { "Online · key not backed up" };
                self.ui.label(cx, ids!(profile_btn.status)).set_text(cx, status);
            }
            Update::Servers(servers) => {
                if let Some(mut rail) = self.ui.widget(cx, ids!(rail)).borrow_mut::<lists::RailList>() {
                    rail.servers = servers.clone();
                }
                lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(rail.list)));
            }
            Update::Server { gid, name, sidebar, members } => {
                if let Some(mut rail) = self.ui.widget(cx, ids!(rail)).borrow_mut::<lists::RailList>() {
                    rail.selected = Some(gid.clone());
                }
                lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(rail.list)));
                self.ui.label(cx, ids!(server_name)).set_text(cx, name);
                if self.ui.label(cx, ids!(notice)).text().starts_with("Joining") {
                    self.notice(cx, "");
                }
                if let Some(mut list) = self.ui.widget(cx, ids!(channels)).borrow_mut::<lists::ChannelList>() {
                    list.rows = sidebar.clone();
                }
                lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(channels.list)));
                if let Some(mut list) = self.ui.widget(cx, ids!(members)).borrow_mut::<lists::MemberList>() {
                    list.rows = members.clone();
                }
                lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(members.list)));
            }
            Update::Channel { gid, channel_id, name, topic, encrypted } => {
                if let Some(mut list) = self.ui.widget(cx, ids!(channels)).borrow_mut::<lists::ChannelList>() {
                    list.selected = Some(channel_id.clone());
                }
                lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(channels.list)));
                self.ui.label(cx, ids!(channel_hash)).set_text(cx, if *encrypted { "🔒" } else { "#" });
                self.ui.label(cx, ids!(channel_name)).set_text(cx, name);
                self.ui.label(cx, ids!(channel_topic)).set_text(cx, topic);
                let _ = gid;
            }
            Update::Timeline { gid, channel_id, rows, can_pin } => {
                let key = (gid.clone(), channel_id.clone());
                let new_channel = self.showing.as_ref() != Some(&key);
                self.showing = Some(key);
                if new_channel {
                    self.clear_bars(cx);
                    self.ui.view(cx, ids!(pins_panel)).set_visible(cx, false);
                }
                if let Some(mut list) = self.ui.widget(cx, ids!(messages)).borrow_mut::<message_list::MessageList>() {
                    list.can_pin = *can_pin;
                    list.set_rows(cx, rows.clone(), new_channel);
                }
                let pins: Vec<lists::PinRow> = rows
                    .iter()
                    .filter(|r| r.pinned)
                    .map(|r| lists::PinRow { id: r.id.clone(), author: r.author.clone(), body: r.body.clone().unwrap_or_default() })
                    .collect();
                if let Some(mut list) = self.ui.widget(cx, ids!(pins)).borrow_mut::<lists::PinsList>() {
                    list.rows = pins;
                }
                lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(pins.list)));
            }
            Update::Invite(link) => {
                cx.copy_to_clipboard(link);
                self.notice(cx, &format!("Invite link copied: {link}"));
            }
            Update::Profile(p) => {
                for (path, value) in [
                    (ids!(p_display), &p.display_name),
                    (ids!(p_username), &p.username),
                    (ids!(p_about), &p.about),
                    (ids!(p_status), &p.status),
                    (ids!(p_status_emoji), &p.status_emoji),
                    (ids!(p_color), &p.color),
                    (ids!(p_color_2), &p.color_2),
                ] {
                    self.ui.text_input(cx, path).set_text(cx, value);
                }
            }
            Update::Relays(relays) => {
                if let Some(mut list) = self.ui.widget(cx, ids!(relay_list)).borrow_mut::<lists::RelayList>() {
                    list.rows = relays.clone();
                }
                lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(relay_list.list)));
            }
            Update::BackedUp(backup) => {
                cx.copy_to_clipboard(backup);
                self.ui.label(cx, ids!(backup_status)).set_text(
                    cx,
                    "✓ Backed up. The encrypted backup (ncryptsec) was copied to your clipboard — store it somewhere safe.",
                );
                self.ui.view(cx, ids!(backup_form)).set_visible(cx, false);
                self.ui.redraw(cx);
            }
            Update::Error(e) => {
                self.notice(cx, &format!("⚠ {e}"));
                self.ui.label(cx, ids!(profile_note)).set_text(cx, &format!("⚠ {e}"));
            }
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

        let list_action = self
            .ui
            .widget(cx, ids!(messages))
            .borrow_mut::<message_list::MessageList>()
            .and_then(|mut l| l.handle_list_actions(cx, actions));
        if let Some(a) = list_action {
            self.message_action(cx, a);
        }
        let tapped = |ui: &WidgetRef, cx: &mut Cx, path: &[LiveId]| ui.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled);
        if tapped(&self.ui, cx, ids!(reply_bar.close)) || tapped(&self.ui, cx, ids!(edit_bar.close)) {
            self.clear_bars(cx);
        }
        if tapped(&self.ui, cx, ids!(pins_btn)) {
            let panel = self.ui.view(cx, ids!(pins_panel));
            panel.set_visible(cx, !panel.visible());
            self.ui.redraw(cx);
        }
        let pin_click = self.ui.widget(cx, ids!(pins)).borrow::<lists::PinsList>().and_then(|p| p.clicked(cx, actions));
        if let Some(id) = pin_click {
            self.ui.view(cx, ids!(pins_panel)).set_visible(cx, false);
            if let Some(mut list) = self.ui.widget(cx, ids!(messages)).borrow_mut::<message_list::MessageList>() {
                list.jump_to(cx, &id);
            }
            self.ui.redraw(cx);
        }

        // Settings overlay
        if tapped(&self.ui, cx, ids!(open_settings)) {
            self.set_settings_open(cx, true);
        }
        if tapped(&self.ui, cx, ids!(close_settings)) {
            self.set_settings_open(cx, false);
        }
        for (i, (nav, _)) in SETTINGS_PAGES.iter().enumerate() {
            if tapped(&self.ui, cx, nav) {
                self.show_settings_page(cx, i);
            }
        }
        if self.ui.button(cx, ids!(copy_npub)).clicked(actions) {
            cx.copy_to_clipboard(&self.npub);
        }
        if self.ui.button(cx, ids!(make_backup)).clicked(actions) {
            let pw = self.ui.text_input(cx, ids!(backup_pw)).text();
            let pw2 = self.ui.text_input(cx, ids!(backup_pw2)).text();
            if pw != pw2 {
                self.ui.label(cx, ids!(backup_status)).set_text(cx, "⚠ The passwords don't match.");
            } else {
                self.send(backend::Command::Backup(pw));
                self.ui.text_input(cx, ids!(backup_pw)).set_text(cx, "");
                self.ui.text_input(cx, ids!(backup_pw2)).set_text(cx, "");
            }
        }
        if self.ui.button(cx, ids!(save_profile)).clicked(actions) {
            let get = |ui: &WidgetRef, cx: &mut Cx, p: &[LiveId]| ui.text_input(cx, p).text();
            let form = backend::ProfileForm {
                display_name: get(&self.ui, cx, ids!(p_display)),
                username: get(&self.ui, cx, ids!(p_username)),
                about: get(&self.ui, cx, ids!(p_about)),
                status: get(&self.ui, cx, ids!(p_status)),
                status_emoji: get(&self.ui, cx, ids!(p_status_emoji)),
                color: get(&self.ui, cx, ids!(p_color)),
                color_2: get(&self.ui, cx, ids!(p_color_2)),
            };
            let bad = [&form.color, &form.color_2].into_iter().find(|c| {
                !c.is_empty() && !(c.len() == 7 && c.starts_with('#') && u32::from_str_radix(&c[1..], 16).is_ok())
            });
            if let Some(c) = bad {
                self.ui.label(cx, ids!(profile_note)).set_text(cx, &format!("⚠ \"{c}\" isn't a #rrggbb color."));
            } else {
                self.send(backend::Command::SaveProfile(form));
                self.ui.label(cx, ids!(profile_note)).set_text(cx, "Saved ✓");
            }
        }
        if self.ui.button(cx, ids!(add_relay)).clicked(actions) {
            let url = self.ui.text_input(cx, ids!(new_relay)).text();
            if !url.trim().is_empty() {
                self.send(backend::Command::AddRelay(url));
                self.ui.text_input(cx, ids!(new_relay)).set_text(cx, "");
            }
        }
        let removed = self.ui.widget(cx, ids!(relay_list)).borrow::<lists::RelayList>().and_then(|l| l.removed(cx, actions));
        if let Some(url) = removed {
            self.send(backend::Command::RemoveRelay(url));
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
        if composer.escaped(actions) {
            self.clear_bars(cx);
        }
        if let Some((text, _)) = composer.returned(actions) {
            let text = text.trim();
            if !text.is_empty() {
                match self.editing.take() {
                    Some(id) => self.send(backend::Command::Edit { id, text: text.to_owned() }),
                    None => {
                        let reply_to = self.reply_to.take();
                        self.send(backend::Command::Send { text: text.to_owned(), reply_to });
                    }
                }
                self.ui.view(cx, ids!(reply_bar)).set_visible(cx, false);
                self.ui.view(cx, ids!(edit_bar)).set_visible(cx, false);
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
        // Esc closes the settings overlay (spec).
        if let Event::KeyDown(k) = event {
            if k.key_code == KeyCode::Escape && self.ui.view(cx, ids!(settings)).visible() {
                self.set_settings_open(cx, false);
            }
        }
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
