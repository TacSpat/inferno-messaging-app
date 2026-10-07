//! Spike 2a: the Rails shell in Makepad, with a 10,000-message list.
//! Layout and sizes follow the spec's visual section and the Rails views
//! (`layouts/application.html.erb`, `shared/_server_rail`, `channels/_channel_item`,
//! `messages/_message`, `channels/show`, `servers/_member_sidebar`).

pub use makepad_widgets;

mod backend;
mod composer_lint;
mod crop;
mod ctxmenu;
mod demo;
mod images;
mod lists;
mod message_format;
mod message_text;
mod message_list;
mod picker;
mod rich_input;
#[allow(dead_code)] // the other six themes land with runtime switching
mod theme;
mod time_fmt;
mod uploads;
mod window_state;

use makepad_widgets::*;

use rich_input::RichInputWidgetRefExt;
use crop::{Crop, Target};
use uploads::Uploads;
use picker::{Cell, GifView, ServerSet};
use inferno_core::gifs::{Collection as GifCollection, Gif};
use std::collections::HashSet;
use backend::{Card, Friend, Home, ServerPerms, ServerSettings};

app_main!(App);

script_mod! {
    use mod.prelude.widgets.*
    use mod.widgets.*

    // Theme tokens, read from the current theme (theme.rs) every time this
    // module runs; switching themes re-runs it (cx.request_style_reload).
    let gray_950 = #(theme::tok("gray_950", 1.0))
    let gray_900 = #(theme::tok("gray_900", 1.0))
    let gray_800 = #(theme::tok("gray_800", 1.0))
    let gray_700 = #(theme::tok("gray_700", 1.0))
    let gray_600 = #(theme::tok("gray_600", 1.0))
    let gray_500 = #(theme::tok("gray_500", 1.0))
    let gray_400 = #(theme::tok("gray_400", 1.0))
    let gray_300 = #(theme::tok("gray_300", 1.0))
    let gray_200 = #(theme::tok("gray_200", 1.0))
    let gray_100 = #(theme::tok("gray_100", 1.0))
    let accent = #(theme::tok("accent", 1.0))
    let accent_light = #(theme::tok("accent_light", 1.0))
    let accent_dark = #(theme::tok("accent_dark", 1.0))
    let confirm = #(theme::tok("confirm", 1.0))
    // Tints used across the shell (spec: one faint accent glow everywhere).
    let accent_00 = #(theme::tok("accent", 0.0))
    let accent_06 = #(theme::tok("accent", 0.06))
    let accent_12 = #(theme::tok("accent", 0.12))
    let accent_15 = #(theme::tok("accent", 0.15))
    let accent_20 = #(theme::tok("accent", 0.2))
    let accent_25 = #(theme::tok("accent", 0.25))
    let accent_30 = #(theme::tok("accent", 0.3))
    let accent_40 = #(theme::tok("accent", 0.4))
    let accent_50 = #(theme::tok("accent", 0.5))
    let gray_700_00 = #(theme::tok("gray_700", 0.0))
    let gray_700_50 = #(theme::tok("gray_700", 0.5))
    let gray_100_60 = #(theme::tok("gray_100", 0.6))
    let gray_400_60 = #(theme::tok("gray_400", 0.6))
    let gray_800_60 = #(theme::tok("gray_800", 0.6))

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
    // (Makepad draws a corner at twice its border_radius number.)
    let RailIcon = RoundedView{
        width: 48 height: 48
        flow: Overlay
        align: Center
        new_batch: true
        draw_bg.color: gray_700
        draw_bg.border_radius: 8.0
        initials := Txt{text: "?" draw_text.text_style.font_size: 10.5}
        pic := Image{visible: false width: 48 height: 48 fit: ImageFit.CropToFill draw_bg.border_radius: 8.0}
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
        hash := Txt{text: "#" draw_text.color: gray_400_60 draw_text.text_style.font_size: 12.5}
        name := Txt{width: Fill text: "channel" draw_text.color: gray_400 draw_text.text_style.font_size: 10.5}
    }

    let CategoryHeader = View{
        width: Fill height: Fit
        padding: Inset{left: 8 right: 8 top: 16 bottom: 4}
        flow: Right spacing: 2
        align: Align{y: 0.5}
        Ico{icon_walk: Walk{width: 12 height: 12} draw_icon.svg: crate_resource("self:resources/icons/chevron_down.svg")}
        label := Txt{width: Fill text: "CATEGORY" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
        // Rails: a hover "+" titled "Create Channel" (manage_channels).
        add := View{visible: false width: Fit height: Fit cursor: MouseCursor.Hand
            Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/plus.svg")}}
    }

    // ─── Member list ─────────────────────────────────────────────────
    let MemberItem = RoundedView{
        width: Fill height: Fit
        cursor: MouseCursor.Hand
        padding: Inset{left: 8 right: 8 top: 4 bottom: 4}
        flow: Right spacing: 12
        align: Align{y: 0.5}
        new_batch: true
        draw_bg.color: #0000
        draw_bg.border_radius: 4.0
        face := View{
            width: 32 height: 32
            flow: Overlay
            avatar := RoundedView{flow: Overlay 
                width: 32 height: 32 align: Center new_batch: true
                draw_bg.color: #x1e1c1b
                draw_bg.border_radius: 16.0
                initial := Txt{text: "?" draw_text.text_style.font_size: 9.5}
                pic := Image{width: 32 height: 32 fit: ImageFit.CropToFill draw_bg.border_radius: 16.0}
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
            // Theme tokens reach shaders as uniforms.
            c_clear: uniform(accent_00)
            c_hover: uniform(accent_06)
            c_flash: uniform(accent_30)
            c_edge: uniform(accent_40)
            pixel: fn() {
                let sdf = Sdf2d.viewport(self.pos * self.rect_size)
                sdf.box(0. 0. self.rect_size.x self.rect_size.y 4.0)
                let fill = mix(self.c_clear, self.c_hover, self.hover)
                sdf.fill(mix(fill, self.c_flash, self.flash))
                sdf.rect(0. 0. 2. self.rect_size.y)
                sdf.fill(mix(self.c_clear, self.c_edge, self.hover))
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



    // Rails' invite embed (max-w-sm, rounded-lg, gray-800/60, gray-700
    // border, 48px rounded-xl icon) with Flutter's Join button; "Joined"
    // opens the server. Dead invites dim with Rails' reason.
    let InviteCard = RoundedView{
        visible: false
        width: 384 height: Fit
        margin: Inset{top: 6 bottom: 2}
        padding: Inset{left: 12 right: 12 top: 12 bottom: 12}
        flow: Right spacing: 12
        align: Align{y: 0.5}
        new_batch: true
        draw_bg.color: gray_800_60
        draw_bg.border_radius: 4.0
        draw_bg.border_size: 1.0
        draw_bg.border_color: gray_700
        icon := RoundedView{width: 48 height: 48 flow: Overlay align: Center new_batch: true
            draw_bg.color: gray_700 draw_bg.border_radius: 6.0
            initial := Txt{text: "?" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 12.0}}
            pic := Image{visible: false width: 48 height: 48 fit: ImageFit.CropToFill draw_bg.border_radius: 6.0}
        }
        View{width: Fill height: Fit flow: Down spacing: 2
            kicker := Txt{text: "You've been invited to join a server" draw_text.color: gray_500 draw_text.text_style.font_size: 8.5}
            name := Txt{width: Fill text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 10.5}}
            detail := Txt{width: Fill text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 8.5}
        }
        join := RoundedView{width: Fit height: Fit padding: Inset{left: 14 right: 14 top: 7 bottom: 7}
            cursor: MouseCursor.Hand new_batch: true
            draw_bg.color: confirm draw_bg.border_radius: 4.0
            label := Txt{text: "Join" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 9.5}}
        }
    }

    // A message body, rendered as Rails does (message_format.rs).
    let MsgBody = mod.widgets.MessageText{
        width: Fill height: Fit
        padding: 0
        font_size: 10.5
        font_color: gray_200
        paragraph_spacing: 4
        pre_code_spacing: 4
        // Rails pills: 0 4px padding, no margin (the typed space separates).
        inline_code_padding: Inset{left: 4 right: 4 top: 0 bottom: 0}
        inline_code_margin: Inset{left: 0 right: 0 top: 0 bottom: 0}
        heading_base_scale: 1.4
        draw_text +: {color: gray_200}
        text_style_normal: theme.font_regular{font_size: 10.5 line_spacing: 1.4}
        text_style_italic: theme.font_italic{font_size: 10.5 line_spacing: 1.4}
        text_style_bold: theme.font_bold{font_size: 10.5 line_spacing: 1.4}
        text_style_bold_italic: theme.font_bold_italic{font_size: 10.5 line_spacing: 1.4}
        text_style_fixed: theme.font_code{font_size: 9.5 line_spacing: 1.4}
        draw_block +: {
            line_color: gray_400
            sep_color: gray_600
            // Rails: 4px gray-600 left border, no fill.
            quote_bg_color: #0000
            quote_fg_color: gray_600
            code_color: gray_900
            selection_color: accent_30
            table_header_bg_color: gray_800
            table_border_color: gray_600
        }
        // Rails' inline images: max-w-sm max-h-72 rounded-lg; GIFs get the fire button.
        media := View{
            width: Fit height: Fit flow: Overlay align: Align{x: 1.0 y: 0.0}
            margin: Inset{top: 4 bottom: 4}
            cursor: MouseCursor.Hand
            img := Image{visible: false width: 384 height: 288 fit: ImageFit.Smallest draw_bg.border_radius: 8.0}
            fire := RoundedView{visible: false width: 28 height: 28 margin: 6 align: Center cursor: MouseCursor.Hand
                new_batch: true draw_bg.color: #x00000099 draw_bg.border_radius: 14.0
                Txt{text: "🔥" draw_text.text_style.font_size: 11.0}}
        }
        link_color: accent_light
        mention_color: accent
        mention_bg: accent_15
        mention_bg_hover: accent_30
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
        draw_bg.border_color: accent_25
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
                    avatar := RoundedView{flow: Overlay cursor: MouseCursor.Hand 
                        width: 40 height: 40
                        margin: Inset{right: 16 top: 2}
                        align: Center
                        new_batch: true
                        draw_bg.color: #x1e1c1b
                        draw_bg.border_radius: 20.0
                        initial := Txt{text: "?" draw_text.text_style.font_size: 10.5}
                        pic := Image{width: 40 height: 40 fit: ImageFit.CropToFill draw_bg.border_radius: 20.0}
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
                            who := View{width: Fit height: Fit cursor: MouseCursor.Hand
                                name := Txt{text: "name" draw_text.text_style.font_size: 10.5}}
                            time := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 9.0}
                        }
                        body := MsgBody{}
                        invite := InviteCard{}
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
                    content := View{width: Fill height: Fit flow: Down
                        body := MsgBody{}
                        invite := InviteCard{}
                    }
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
                    draw_bg.border_radius: 6.0
                    pic +: {draw_bg.border_radius: 6.0}
                }
            }
        }
    }

    mod.widgets.ChannelListBase = #(lists::ChannelList::register_widget(vm))
    mod.widgets.ChannelList = set_type_default() do mod.widgets.ChannelListBase{
        width: Fill height: Fill
        flow: Overlay
        cursor: MouseCursor.Default
        // Spec: drag-and-drop shows a 2px accent drop line.
        drop_line := SolidView{visible: false width: Fill height: 2 draw_bg.color: accent}
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Category := CategoryHeader{margin: Inset{left: 8 right: 8} cursor: MouseCursor.Default}
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
                item := ChannelItem{hash.draw_text.color: gray_100_60 name.draw_text.color: #xffffff}
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
            Member := MemberItem{cursor: MouseCursor.Default}
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
    // Rails' reply/edit/spoiler bars: gray-700, rounded top, px-4 py-2,
    // 1px gray-600 rule under; the reply bar adds a 2px accent/.5 left edge
    // over an accent/.06 → clear gradient.
    let ComposerBar = View{
        visible: false
        width: Fill height: Fit
        padding: Inset{left: 16 right: 10 top: 8 bottom: 8}
        flow: Right spacing: 6
        align: Align{y: 0.5}
        show_bg: true
        new_batch: true
        draw_bg +: {
            edge: uniform(0.0)
            fill: uniform(gray_700)
            tint: uniform(accent_06)
            seam: uniform(accent_40)
            rule: uniform(gray_600)
            pixel: fn() {
                let sdf = Sdf2d.viewport(self.pos * self.rect_size)
                // Taller than the rect, so only the top corners round.
                sdf.box(0. 0. self.rect_size.x self.rect_size.y + 8.0 8.0)
                let c = mix(self.fill, vec4(self.tint.rgb, 1.0), self.tint.a * (1.0 - self.pos.x) * self.edge)
                sdf.fill(c)
                sdf.rect(0. self.rect_size.y - 1.0 self.rect_size.x 1.0)
                sdf.fill(self.rule)
                sdf.rect(0. 0. 2.0 * self.edge self.rect_size.y)
                sdf.fill(self.seam)
                return sdf.result
            }
        }
        lead := Txt{text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 9.5}
        who := Txt{text: "" draw_text.color: accent_light draw_text.text_style: theme.font_bold{font_size: 9.5}}
        label := Txt{width: Fill text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 9.5
            flow: Flow.Right{wrap: false} text_overflow: TextOverflow.Ellipsis}
        close := ToolBtn{padding: 2 Ico{icon_walk: Walk{width: 14 height: 14} draw_icon.color: gray_400
            draw_icon.svg: crate_resource("self:resources/icons/close.svg")}}
    }

    // Composer icon: gray-400, accent on hover (Rails' ember buttons).
    let ComposerBtn = View{
        width: Fit height: Fit padding: 8
        cursor: MouseCursor.Hand
        ico := Ico{icon_walk: Walk{width: 20 height: 20} draw_icon.color: gray_400}
        animator: Animator{
            hover: {
                default: @off
                off: AnimatorState{from: {all: Forward {duration: 0.15}} apply: {ico: {draw_icon: {color: gray_400}}}}
                on: AnimatorState{from: {all: Forward {duration: 0.15}} apply: {ico: {draw_icon: {color: accent}}}}
            }
        }
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
    // Rails menu item: px-2.5 py-1.5 text-sm gray-300, hover gray-700 + white.
    let MenuItem = RoundedView{
        width: Fill height: Fit
        padding: Inset{left: 10 right: 10 top: 6 bottom: 6}
        flow: Right spacing: 8
        align: Align{y: 0.5}
        cursor: MouseCursor.Hand
        new_batch: true
        draw_bg +: {
            hover: instance(0.0)
            c_clear: uniform(gray_700_00)
            c_hover: uniform(gray_700)
            pixel: fn() {
                let sdf = Sdf2d.viewport(self.pos * self.rect_size)
                sdf.box(0. 0. self.rect_size.x self.rect_size.y 4.0)
                sdf.fill(mix(self.c_clear, self.c_hover, self.hover))
                return sdf.result
            }
        }
        animator: Animator{
            hover: {
                default: @off
                off: AnimatorState{from: {all: Forward {duration: 0.1}} apply: {draw_bg: {hover: 0.0}}}
                on: AnimatorState{from: {all: Forward {duration: 0.1}} apply: {draw_bg: {hover: 1.0}}}
            }
        }
        icon := Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.color: gray_300}
        label := Txt{text: "" draw_text.color: gray_300 draw_text.text_style.font_size: 10.5}
    }

    // One context-menu slot: an optional separator, then the item.
    let CtxSlot = View{
        visible: false
        width: Fill height: Fit
        flow: Down
        sep := SolidView{visible: false width: Fill height: 1 margin: Inset{top: 4 bottom: 4} draw_bg.color: gray_700}
        item := MenuItem{icon.icon_walk: Walk{width: 0 height: 16}}
    }

    // Rails form card: gray-800, rounded-xl, border gray-700/50, p-5.
    let Card = RoundedView{
        width: Fill height: Fit
        flow: Down spacing: 4
        padding: 20
        margin: Inset{bottom: 16}
        new_batch: true
        draw_bg.color: gray_800
        draw_bg.border_radius: 12.0
        draw_bg.border_size: 1.0
        draw_bg.border_color: gray_700_50
    }

    let FieldLabel = Txt{
        margin: Inset{top: 16 bottom: 6}
        draw_text.color: gray_500
        draw_text.text_style: theme.font_bold{font_size: 8.0}
    }
    let Field = TextInput{width: Fill height: 36}
    // Text edited in place on a card: no well, just the text.
    let Toast = RoundedView{
        visible: false
        width: Fit height: Fit
        padding: Inset{left: 16 right: 16 top: 8 bottom: 8}
        new_batch: true
        draw_bg.color: #x16a34a
        draw_bg.border_radius: 8.0
        draw_bg.border_size: 1.0
        draw_bg.border_color: #x00000040
        label := Txt{width: Fit text: "" draw_text.color: #xffffff draw_text.text_style.font_size: 9.5}
    }
    let CardInput = TextInput{width: Fill height: Fit padding: Inset{left: 2 right: 2 top: 2 bottom: 2}
        draw_bg +: {pixel: fn() { return vec4(0.0, 0.0, 0.0, 0.0) }}
        draw_text +: {color: #xffffff color_empty: #xffffff59}
    }
    let PageTitle = Txt{
        margin: Inset{bottom: 8}
        draw_text.color: #xffffff
        draw_text.text_style: theme.font_bold{font_size: 15.0}
    }
    let Hint = Txt{width: Fill draw_text.color: gray_400 draw_text.text_style.font_size: 9.5}
    let Swatch = RoundedView{width: 28 height: 28 cursor: MouseCursor.Hand new_batch: true draw_bg.border_radius: 2.0}
    let Divider = SolidView{width: Fill height: 1 margin: Inset{top: 24} draw_bg.color: gray_700}
    // Rails' text button (Remove Icon): danger-light, no well.
    let LinkBtn = View{width: Fit height: Fit padding: 4 cursor: MouseCursor.Hand
        label := Txt{text: "" draw_text.color: #xf87171 draw_text.text_style.font_size: 9.0}}

    mod.widgets.RolePickerBase = #(lists::RolePicker::register_widget(vm))
    mod.widgets.RolePicker = set_type_default() do mod.widgets.RolePickerBase{
        width: Fill height: 120
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Role := View{
                width: Fill height: Fit
                padding: Inset{top: 4 bottom: 4}
                flow: Right spacing: 8
                cursor: MouseCursor.Hand
                mark := Txt{width: 14 text: "·" draw_text.color: accent_light}
                name := Txt{text: "" draw_text.color: gray_200}
            }
        }
    }

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

    // ─── Server settings widgets (lists.rs) ──────────────────────────
    mod.widgets.PermListBase = #(lists::PermList::register_widget(vm))
    // Rails' toggle: w-11 h-6 track, white knob (lists::set_switch).
    let Switch = RoundedView{width: 44 height: 24 padding: 2 align: Align{x: 0.0 y: 0.5} new_batch: true
        draw_bg.color: gray_600 draw_bg.border_radius: 6.0
        RoundedView{width: 20 height: 20 draw_bg.color: #xffffff draw_bg.border_radius: 5.0}}

    mod.widgets.PermList = set_type_default() do mod.widgets.PermListBase{
        width: Fill height: 560
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Group := Txt{margin: Inset{top: 18 bottom: 8} draw_text.color: gray_400
                draw_text.text_style: theme.font_bold{font_size: 8.5}}
            Perm := View{
                width: Fill height: Fit
                padding: Inset{top: 8 bottom: 8}
                flow: Right spacing: 16
                align: Align{y: 0.5}
                cursor: MouseCursor.Hand
                text := View{width: Fill height: Fit flow: Down spacing: 2
                    title := Txt{text: "" draw_text.color: #xffffff draw_text.text_style.font_size: 10.5}
                    label := Txt{width: Fill text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 9.0}}
                switch := Switch{}
            }
        }
    }

    mod.widgets.RoleListBase = #(lists::RoleList::register_widget(vm))
    mod.widgets.RoleList = set_type_default() do mod.widgets.RoleListBase{
        width: Fill height: 480
        flow: Overlay
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            // Rails: px-3 py-2 rounded, gray-800 (hover gray-700), dot, name, count.
            Role := RoundedView{
                width: Fill height: Fit
                margin: Inset{bottom: 4}
                padding: Inset{left: 12 right: 12 top: 8 bottom: 8}
                flow: Right spacing: 12
                align: Align{y: 0.5}
                cursor: MouseCursor.Hand
                new_batch: true
                draw_bg.color: gray_800
                draw_bg.border_radius: 2.0
                dot := RoundedView{width: 12 height: 12 draw_bg.color: #x99aab5 draw_bg.border_radius: 3.0}
                name := Txt{width: Fill text: "" draw_text.color: #xffffff}
                count := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 8.5}
            }
            Selected := RoundedView{
                width: Fill height: Fit
                margin: Inset{bottom: 4}
                padding: Inset{left: 12 right: 12 top: 8 bottom: 8}
                flow: Right spacing: 12
                align: Align{y: 0.5}
                cursor: MouseCursor.Hand
                new_batch: true
                draw_bg.color: gray_600
                draw_bg.border_radius: 2.0
                dot := RoundedView{width: 12 height: 12 draw_bg.color: #x99aab5 draw_bg.border_radius: 3.0}
                name := Txt{width: Fill text: "" draw_text.color: #xffffff}
                count := Txt{text: "" draw_text.color: gray_300 draw_text.text_style.font_size: 8.5}
            }
        }
        drop_line := SolidView{visible: false width: Fill height: 2 draw_bg.color: accent}
    }

    let SmallBtn = RoundedView{
        width: Fit height: Fit
        padding: Inset{left: 10 right: 10 top: 5 bottom: 5}
        cursor: MouseCursor.Hand
        new_batch: true
        draw_bg.color: gray_700
        draw_bg.border_radius: 4.0
        t := Txt{text: "" draw_text.color: gray_200 draw_text.text_style.font_size: 9.0}
    }

    mod.widgets.PeopleListBase = #(lists::PeopleList::register_widget(vm))
    mod.widgets.PeopleList = set_type_default() do mod.widgets.PeopleListBase{
        width: Fill height: 520
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Person := RoundedView{
                width: Fill height: Fit
                margin: Inset{bottom: 6}
                padding: Inset{left: 12 right: 8 top: 8 bottom: 8}
                flow: Right spacing: 8
                align: Align{y: 0.5}
                new_batch: true
                draw_bg.color: gray_800
                draw_bg.border_radius: 6.0
                View{width: Fill height: Fit flow: Down spacing: 2
                    name := Txt{text: "" draw_text.color: gray_100}
                    detail := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 9.0}
                }
                btn_a := SmallBtn{}
                btn_b := SmallBtn{t.draw_text.color: #xf87171}
            }
            Empty := Hint{text: "Nobody here." margin: 8}
        }
    }

    // Rails' theme picker tile: 80×24 gradient swatch (135°, 0/40/100%),
    // name under it; the picked one gets a brighter 2px border.
    let ThemeTile = RoundedView{
        width: Fit height: Fit flow: Down spacing: 4 padding: 8
        cursor: MouseCursor.Hand
        new_batch: true
        draw_bg.color: #x00000066
        draw_bg.border_radius: 8.0
        draw_bg.border_size: 2.0
        draw_bg.border_color: #xffffff1a
        swatch := View{width: 80 height: 24 show_bg: true
            draw_bg +: {
                c0: uniform(vec4(0. 0. 0. 1.))
                c1: uniform(vec4(0. 0. 0. 1.))
                c2: uniform(vec4(0. 0. 0. 1.))
                pixel: fn() {
                    let sdf = Sdf2d.viewport(self.pos * self.rect_size)
                    sdf.box(0. 0. self.rect_size.x self.rect_size.y 4.0)
                    let t = (self.pos.x + self.pos.y) * 0.5
                    let c = mix(self.c0, self.c1, clamp(t / 0.4, 0.0, 1.0))
                    sdf.fill(mix(c, self.c2, clamp((t - 0.4) / 0.6, 0.0, 1.0)))
                    return sdf.result
                }
            }
        }
        label := Txt{text: "" draw_text.color: gray_300 draw_text.text_style.font_size: 8.5}
    }

    // Rails' profile card (users/_card): w-72, 80px banner, 66px avatar
    // ring overlapping it by 35px, black/30 panel, uppercase section heads.
    let CardSection = View{width: Fill height: Fit flow: Down spacing: 4
        SolidView{width: Fill height: 1 margin: Inset{bottom: 4} draw_bg.color: #xffffff1a}
    }
    let CardHead = Txt{draw_text.color: #xffffff80 draw_text.text_style: theme.font_bold{font_size: 7.5}}
    let RoleChip = RoundedView{visible: false width: Fit height: Fit flow: Right spacing: 4 align: Align{y: 0.5}
        padding: Inset{left: 6 right: 6 top: 2 bottom: 2} new_batch: true
        draw_bg.color: #x0000004d draw_bg.border_radius: 4.0 draw_bg.border_size: 1.0 draw_bg.border_color: #xffffff1a
        dot := RoundedView{width: 8 height: 8 draw_bg.color: #x99aab5 draw_bg.border_radius: 4.0}
        label := Txt{text: "" draw_text.color: #xffffffcc draw_text.text_style.font_size: 8.5}
    }
    let ProfileCard = RoundedView{
        width: 288 height: Fit
        flow: Down
        new_batch: true
        draw_bg +: {
            c0: uniform(vec4(0.118 0.11 0.106 1.))
            c1: uniform(vec4(0.118 0.11 0.106 1.))
            banner: uniform(vec4(0.17 0.16 0.16 1.))
            pixel: fn() {
                let sdf = Sdf2d.viewport(self.pos * self.rect_size)
                sdf.box(0. 0. self.rect_size.x self.rect_size.y 8.0)
                let t = clamp((self.pos.x + self.pos.y) * 0.5, 0.0, 1.0)
                let body = mix(self.c0, self.c1, t)
                let px = self.pos.y * self.rect_size.y
                sdf.fill_keep(mix(self.banner, body, step(80.0, px)))
                // Stands in for Rails' shadow-2xl: the banner is gray-700,
                // the same as the chat behind it.
                sdf.stroke(vec4(0.0, 0.0, 0.0, 0.5), 1.5)
                return sdf.result
            }
        }
        // Banner: the image covers the top 80px (rounded top corners).
        View{width: Fill height: 80
            banner := Image{width: Fill height: 80 fit: ImageFit.CropToFill draw_bg.border_radius: 8.0}
        }
        View{width: Fill height: Fit flow: Down padding: Inset{left: 12 right: 12 bottom: 12 top: 4} margin: Inset{top: -35}
            View{width: 66 height: 66 flow: Overlay margin: Inset{bottom: 8}
                ring := RoundedView{width: 66 height: 66 padding: 5 new_batch: true
                    draw_bg.color: #x1e1c1b draw_bg.border_radius: 33.0
                    avatar := RoundedView{flow: Overlay width: 56 height: 56 align: Center new_batch: true
                        draw_bg.color: #x1e1c1b draw_bg.border_radius: 28.0
                        initial := Txt{text: "?" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 15.0}}
                        pic := Image{width: 56 height: 56 fit: ImageFit.CropToFill draw_bg.border_radius: 28.0}
                    }
                }
                View{width: 66 height: 66 padding: Inset{left: 46 top: 46}
                    dot := RoundedView{width: 18 height: 18 new_batch: true
                        draw_bg.color: #x22c55e draw_bg.border_radius: 9.0
                        draw_bg.border_size: 3.0 draw_bg.border_color: #x1e1c1b}
                }
            }
            RoundedView{width: Fill height: Fit flow: Down spacing: 8 padding: 12 new_batch: true
                draw_bg.color: #x0000004d draw_bg.border_radius: 8.0
                View{width: Fill height: Fit flow: Down spacing: 2
                    name := Txt{text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 12.0}}
                    tag := Txt{text: "" draw_text.color: #xffffff99 draw_text.text_style.font_size: 8.5}
                    status := Txt{text: "" draw_text.color: #xffffffb3 draw_text.text_style.font_size: 8.5}
                }
                about_box := CardSection{
                    CardHead{text: "ABOUT ME"}
                    about := Txt{width: Fill text: "" draw_text.color: #xffffffcc draw_text.text_style.font_size: 9.0}
                }
                roles_box := CardSection{
                    CardHead{text: "ROLES"}
                    View{width: Fill height: Fit flow: Right{wrap: true} spacing: 4
                        r0 := RoleChip{} r1 := RoleChip{} r2 := RoleChip{} r3 := RoleChip{} r4 := RoleChip{}
                        r5 := RoleChip{} r6 := RoleChip{} r7 := RoleChip{} r8 := RoleChip{} r9 := RoleChip{}
                    }
                }
                CardSection{
                    CardHead{text: "MEMBER SINCE"}
                    since := Txt{text: "" draw_text.color: #xffffffcc draw_text.text_style.font_size: 9.0}
                }
                // Flutter's shortcuts on the card.
                View{width: Fill height: Fit flow: Right spacing: 8 margin: Inset{top: 4}
                    card_message := RoundedView{width: Fill height: 30 align: Center cursor: MouseCursor.Hand new_batch: true
                        draw_bg.color: accent draw_bg.border_radius: 4.0
                        Txt{text: "Message" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 9.0}}}
                    card_friend := RoundedView{width: Fill height: 30 align: Center cursor: MouseCursor.Hand new_batch: true
                        draw_bg.color: #x00000066 draw_bg.border_radius: 4.0
                        label := Txt{text: "Add Friend" draw_text.color: #xffffffcc draw_text.text_style.font_size: 9.0}}
                }
                View{width: Fill height: Fit flow: Right spacing: 8
                    card_copy := RoundedView{width: Fill height: 30 align: Center cursor: MouseCursor.Hand new_batch: true
                        draw_bg.color: #x00000066 draw_bg.border_radius: 4.0
                        Txt{text: "Copy User ID" draw_text.color: #xffffffcc draw_text.text_style.font_size: 9.0}}
                }
            }
        }
    }

    // DM sidebar row (Rails: px-2.5 py-1.5 rounded, 32px avatar, ml-2.5 name,
    // 18px accent unread badge).
    mod.widgets.DmListBase = #(lists::DmList::register_widget(vm))
    mod.widgets.DmList = set_type_default() do mod.widgets.DmListBase{
        width: Fill height: Fill
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Conv := RoundedView{
                width: Fill height: Fit
                padding: Inset{left: 10 right: 10 top: 6 bottom: 6}
                margin: Inset{bottom: 2}
                flow: Right spacing: 10 align: Align{y: 0.5}
                cursor: MouseCursor.Hand
                new_batch: true
                draw_bg.color: #0000 draw_bg.border_radius: 4.0
                avatar := RoundedView{flow: Overlay width: 32 height: 32 align: Center new_batch: true
                    draw_bg.color: #x1e1c1b draw_bg.border_radius: 16.0
                    initial := Txt{text: "?" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 10.0}}
                    pic := Image{width: 32 height: 32 fit: ImageFit.CropToFill draw_bg.border_radius: 16.0}}
                name := Txt{width: Fill text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 10.5
                    flow: Flow.Right{wrap: false} text_overflow: TextOverflow.Ellipsis}
                badge := RoundedView{visible: false width: Fit height: 18 padding: Inset{left: 5 right: 5} align: Center new_batch: true
                    draw_bg.color: accent draw_bg.border_radius: 9.0
                    count := Txt{text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 8.0}}}
            }
        }
    }

    // Friends page rows (Rails conversations#index: 36px avatar, name,
    // status line, round 36px action buttons).
    let FriendBtn = RoundedView{width: 36 height: 36 align: Center cursor: MouseCursor.Hand new_batch: true
        draw_bg.color: gray_700 draw_bg.border_radius: 18.0}
    mod.widgets.FriendListBase = #(lists::FriendList::register_widget(vm))
    mod.widgets.FriendList = set_type_default() do mod.widgets.FriendListBase{
        width: Fill height: Fill
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Head := Txt{width: Fill padding: Inset{left: 8 top: 12 bottom: 8} text: ""
                draw_text.color: gray_400 draw_text.text_style: theme.font_bold{font_size: 8.5}}
            Empty := View{width: Fill height: Fit padding: Inset{top: 64} align: Align{x: 0.5}
                text := Txt{text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 10.0}}
            Person := View{
                width: Fill height: Fit
                padding: Inset{left: 8 right: 8 top: 10 bottom: 10}
                flow: Right spacing: 12 align: Align{y: 0.5}
                avatar := RoundedView{flow: Overlay width: 36 height: 36 align: Center new_batch: true
                    draw_bg.color: gray_600 draw_bg.border_radius: 18.0
                    initial := Txt{text: "?" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 10.0}}
                    pic := Image{width: 36 height: 36 fit: ImageFit.CropToFill draw_bg.border_radius: 18.0}}
                View{width: Fill height: Fit flow: Down spacing: 2
                    name := Txt{text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 10.5}}
                    sub := Txt{text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 8.5}
                }
                msg_btn := FriendBtn{Ico{icon_walk: Walk{width: 18 height: 18} draw_icon.color: gray_300
                    draw_icon.svg: crate_resource("self:resources/icons/message.svg")}}
                add_btn := FriendBtn{Ico{icon_walk: Walk{width: 18 height: 18} draw_icon.color: #x4ade80
                    draw_icon.svg: crate_resource("self:resources/icons/user_plus.svg")}}
                accept_btn := FriendBtn{Ico{icon_walk: Walk{width: 18 height: 18} draw_icon.color: #x4ade80
                    draw_icon.svg: crate_resource("self:resources/icons/check.svg")}}
                decline_btn := FriendBtn{Ico{icon_walk: Walk{width: 18 height: 18} draw_icon.color: #xf87171
                    draw_icon.svg: crate_resource("self:resources/icons/close.svg")}}
                remove_btn := FriendBtn{Ico{icon_walk: Walk{width: 18 height: 18} draw_icon.color: #xf87171
                    draw_icon.svg: crate_resource("self:resources/icons/user_x.svg")}}
                unblock_btn := RoundedView{width: Fit height: 30 padding: Inset{left: 12 right: 12} align: Center
                    cursor: MouseCursor.Hand new_batch: true draw_bg.color: gray_700 draw_bg.border_radius: 4.0
                    Txt{text: "Unblock" draw_text.color: gray_300 draw_text.text_style.font_size: 9.5}}
            }
        }
    }

    // Rails' friends page tab pill: px-3 py-1.5 rounded, bg-gray-600 when on.
    let TabPill = RoundedView{width: Fit height: 30 padding: Inset{left: 12 right: 12} align: Center flow: Right spacing: 6
        cursor: MouseCursor.Hand new_batch: true draw_bg.color: #0000 draw_bg.border_radius: 4.0
        label := Txt{text: "" draw_text.color: gray_300 draw_text.text_style: theme.font_bold{font_size: 9.5}}}

    // ─── Picker (Rails' unified picker) ─────────────────────────────
    // Cells: Rails' w-8 h-8 text-xl; custom emoji w-6 h-6.
    let EmojiCell = RoundedView{
        width: 38 height: 36 flow: Overlay align: Center
        cursor: MouseCursor.Hand new_batch: true
        draw_bg +: {
            hover: instance(0.0)
            on: uniform(gray_700)
            pixel: fn() {
                let sdf = Sdf2d.viewport(self.pos * self.rect_size)
                sdf.box(1. 1. self.rect_size.x - 2. self.rect_size.y - 2. 4.0)
                sdf.fill(vec4(self.on.rgb, self.on.a * self.hover))
                return sdf.result
            }
        }
        glyph := Txt{text: "" draw_text.text_style.font_size: 15.0}
        img := Image{visible: false width: 24 height: 24 fit: ImageFit.Smallest}
        animator: Animator{
            hover: {
                default: @off
                off: AnimatorState{from: {all: Forward {duration: 0.08}} apply: {draw_bg: {hover: 0.0}}}
                on: AnimatorState{from: {all: Forward {duration: 0.08}} apply: {draw_bg: {hover: 1.0}}}
            }
        }
    }
    let StickerCell = RoundedView{
        width: 116 height: 116 padding: 4 align: Center
        cursor: MouseCursor.Hand new_batch: true
        draw_bg.color: gray_700 draw_bg.border_radius: 4.0
        img := Image{visible: false width: 108 height: 108 fit: ImageFit.Smallest}
    }
    let GifTileView = RoundedView{
        width: 181 height: 72 flow: Right spacing: 10 align: Align{y: 0.5} padding: Inset{left: 12 right: 12}
        cursor: MouseCursor.Hand new_batch: true
        draw_bg.color: gray_700 draw_bg.border_radius: 6.0
        icon := Txt{text: "" draw_text.text_style.font_size: 16.0}
        View{width: Fill height: Fit flow: Down spacing: 2
            name := Txt{width: Fill text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 9.5}
                flow: Flow.Right{wrap: false} text_overflow: TextOverflow.Ellipsis}
            sub := Txt{text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 8.0}
        }
    }
    let GifCell = RoundedView{
        width: 181 height: 120 flow: Overlay align: Align{x: 1.0 y: 0.0}
        cursor: MouseCursor.Hand new_batch: true
        draw_bg.color: gray_900 draw_bg.border_radius: 6.0
        img := Image{visible: false width: 181 height: 120 fit: ImageFit.CropToFill draw_bg.border_radius: 6.0}
        fire := RoundedView{width: 28 height: 28 margin: 4 align: Center cursor: MouseCursor.Hand new_batch: true
            draw_bg.color: #x00000099 draw_bg.border_radius: 14.0
            glyph := Txt{text: "🔥" draw_text.text_style.font_size: 11.0}}
    }
    mod.widgets.PickerListBase = #(lists::PickerList::register_widget(vm))
    mod.widgets.PickerList = set_type_default() do mod.widgets.PickerListBase{
        width: Fill height: Fill
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Head := View{width: Fill height: 26 flow: Right spacing: 4 align: Align{y: 0.5}
                padding: Inset{left: 4 top: 6} cursor: MouseCursor.Hand
                open := View{width: Fit height: Fit Ico{icon_walk: Walk{width: 12 height: 12} draw_icon.color: gray_400
                    draw_icon.svg: crate_resource("self:resources/icons/chevron_down.svg")}}
                shut := View{width: Fit height: Fit Ico{icon_walk: Walk{width: 12 height: 12} draw_icon.color: gray_400
                    draw_icon.svg: crate_resource("self:resources/icons/chevron_right.svg")}}
                title := Txt{text: "" draw_text.color: gray_400 draw_text.text_style: theme.font_bold{font_size: 7.5}}
            }
            Cells := View{width: Fill height: Fit flow: Right
                c0 := EmojiCell{}
                c1 := EmojiCell{}
                c2 := EmojiCell{}
                c3 := EmojiCell{}
                c4 := EmojiCell{}
                c5 := EmojiCell{}
                c6 := EmojiCell{}
                c7 := EmojiCell{}
                c8 := EmojiCell{}
            }
            Stickers := View{width: Fill height: Fit flow: Right spacing: 4 margin: Inset{bottom: 4}
                s0 := StickerCell{} s1 := StickerCell{} s2 := StickerCell{}
            }
            // Rails' GIF home: 2-column tiles (Favorites, Trending, collections).
            Tiles := View{width: Fill height: Fit flow: Right spacing: 6 margin: Inset{bottom: 6}
                g0 := GifTileView{} g1 := GifTileView{}
            }
            Gifs := View{width: Fill height: Fit flow: Right spacing: 6 margin: Inset{bottom: 6}
                g0 := GifCell{} g1 := GifCell{}
            }
            Empty := Txt{width: Fill padding: 16 text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 9.5}
        }
    }
    // Rails: tabs text-xs semibold, the active one with a 2px accent underline.
    let PickerTab = View{width: Fill height: 36 flow: Down align: Align{x: 0.5 y: 1.0} cursor: MouseCursor.Hand
        label := Txt{text: "" margin: Inset{bottom: 8} draw_text.color: gray_400 draw_text.text_style: theme.font_bold{font_size: 8.5}}
        line := SolidView{width: Fill height: 2 draw_bg.color: accent}
    }
    // Rails' picker: 384 wide, min(420px, 60vh) tall, gray-800, 1px gray-700.
    let PickerPanel = RoundedView{
        visible: false
        width: 384 height: 420
        flow: Down
        new_batch: true
        draw_bg.color: gray_800
        draw_bg.border_radius: 8.0
        draw_bg.border_size: 1.0
        draw_bg.border_color: gray_700
        tabs := View{width: Fill height: Fit flow: Right padding: Inset{left: 8 right: 8}
            tab_gifs := PickerTab{label.text: "GIFs"}
            tab_stickers := PickerTab{label.text: "Stickers"}
            tab_emoji := PickerTab{label.text: "Emoji"}
        }
        SolidView{width: Fill height: 1 draw_bg.color: gray_700}
        RoundedView{width: Fill height: 32 margin: 8 padding: Inset{left: 8 right: 8} align: Align{y: 0.5} new_batch: true
            draw_bg.color: gray_900 draw_bg.border_radius: 4.0
            search := TextInput{width: Fill height: 30 empty_text: "Search..."
                draw_bg +: {pixel: fn() { return vec4(0.0, 0.0, 0.0, 0.0) }}
                draw_text +: {color: gray_200 color_empty: gray_500}}
        }
        // GIF tab: where you are, and adding without a search service.
        gif_bar := View{visible: false width: Fill height: Fit flow: Down spacing: 6 padding: Inset{left: 8 right: 8 bottom: 6}
            View{width: Fill height: Fit flow: Right spacing: 8 align: Align{y: 0.5}
                gif_back := View{width: Fit height: Fit padding: 4 cursor: MouseCursor.Hand
                    Txt{text: "‹ Back" draw_text.color: gray_300 draw_text.text_style.font_size: 9.0}}
                gif_title := Txt{width: Fill text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 9.5}}
            }
            gif_link := TextInput{width: Fill height: 30 empty_text: "Paste a GIF link to add it to favorites"}
        }
        new_collection := View{visible: false width: Fill height: Fit padding: Inset{left: 8 right: 8 bottom: 6}
            collection_name := TextInput{width: Fill height: 30 empty_text: "Name the collection, then press Enter"}
        }
        View{width: Fill height: Fill padding: Inset{left: 8 right: 8 bottom: 8}
            items := mod.widgets.PickerList{}
        }
    }

    // Flutter's catalog card: banner (or the initial), icon and name, two
    // lines of description, type and 18+ tags; Joined in green.
    let DiscoverCard = RoundedView{
        width: 216 height: Fit flow: Down
        cursor: MouseCursor.Hand new_batch: true
        draw_bg.color: gray_900 draw_bg.border_radius: 5.0
        draw_bg.border_size: 1.0 draw_bg.border_color: gray_700_50
        banner := View{width: Fill height: 100 flow: Overlay align: Center
            RoundedView{width: Fill height: 100 draw_bg.color: gray_700 draw_bg.border_radius: 5.0}
            initial := Txt{text: "" draw_text.color: gray_400 draw_text.text_style: theme.font_bold{font_size: 24.0}}
            img := Image{visible: false width: Fill height: 100 fit: ImageFit.CropToFill draw_bg.border_radius: 5.0}
            View{width: Fill height: Fill align: Align{x: 1.0 y: 0.0} padding: 8
                joined := RoundedView{visible: false width: Fit height: Fit padding: Inset{left: 8 right: 8 top: 4 bottom: 4}
                    flow: Right spacing: 4 align: Align{y: 0.5}
                    new_batch: true draw_bg.color: #x16a34ae6 draw_bg.border_radius: 2.0
                    Ico{icon_walk: Walk{width: 12 height: 12} draw_icon.color: #xffffff draw_icon.svg: crate_resource("self:resources/icons/check.svg")}
                    Txt{text: "Joined" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 8.0}}}
            }
        }
        View{width: Fill height: Fit flow: Down spacing: 8 padding: 12
            head := View{width: Fill height: Fit flow: Right spacing: 10 align: Align{y: 0.5}
                icon := RoundedView{width: 32 height: 32 flow: Overlay align: Center new_batch: true
                    draw_bg.color: gray_700 draw_bg.border_radius: 4.0
                    initial := Txt{text: "" draw_text.color: gray_200 draw_text.text_style: theme.font_bold{font_size: 10.0}}
                    pic := Image{visible: false width: 32 height: 32 fit: ImageFit.CropToFill draw_bg.border_radius: 4.0}}
                name := Txt{width: Fill text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 10.5}}
            }
            about := Txt{width: Fill text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
            tags := View{width: Fill height: Fit flow: Right spacing: 4
                ty := RoundedView{width: Fit height: Fit padding: Inset{left: 6 right: 6 top: 2 bottom: 2} new_batch: true
                    draw_bg.color: gray_700 draw_bg.border_radius: 2.0
                    label := Txt{text: "" draw_text.color: gray_200 draw_text.text_style: theme.font_bold{font_size: 7.5}}}
                age := RoundedView{visible: false width: Fit height: Fit padding: Inset{left: 6 right: 6 top: 2 bottom: 2} new_batch: true
                    draw_bg.color: accent_20 draw_bg.border_radius: 2.0
                    Txt{text: "18+" draw_text.color: accent draw_text.text_style: theme.font_bold{font_size: 7.5}}}
            }
        }
    }

    // Rails' checkbox: 16px, gray-900 well; accent with a check when on.
    let CheckBox16 = RoundedView{width: 16 height: 16 align: Center cursor: MouseCursor.Hand new_batch: true
        draw_bg.color: gray_900 draw_bg.border_radius: 2.0 draw_bg.border_size: 1.0 draw_bg.border_color: gray_600
        mark := Ico{icon_walk: Walk{width: 12 height: 12} draw_icon.color: #xffffff00
            draw_icon.svg: crate_resource("self:resources/icons/check.svg")}}

    // Rails' role badge: gray-700 pill, coloured dot, name.
    let RoleBadge = RoundedView{visible: false width: Fit height: Fit padding: Inset{left: 6 right: 8 top: 2 bottom: 2}
        flow: Right spacing: 4 align: Align{y: 0.5} new_batch: true
        draw_bg.color: gray_700 draw_bg.border_radius: 2.0
        dot := RoundedView{width: 8 height: 8 draw_bg.color: #x99aab5 draw_bg.border_radius: 4.0}
        name := Txt{text: "" draw_text.color: gray_200 draw_text.text_style.font_size: 8.0}}

    mod.widgets.MemberAdminListBase = #(lists::MemberAdminList::register_widget(vm))
    mod.widgets.MemberAdminList = set_type_default() do mod.widgets.MemberAdminListBase{
        width: Fill height: 560
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Member := RoundedView{
                width: Fill height: Fit
                margin: Inset{bottom: 8}
                padding: Inset{left: 16 right: 12 top: 12 bottom: 12}
                flow: Right spacing: 12
                align: Align{y: 0.5}
                new_batch: true
                draw_bg.color: gray_800
                draw_bg.border_radius: 4.0
                // An empty slot where there's nothing to select (Rails).
                slot := View{width: 16 height: 16
                    check := CheckBox16{}}
                avatar := RoundedView{width: 40 height: 40 flow: Overlay align: Center new_batch: true
                    draw_bg.color: #x1e1c1b draw_bg.border_radius: 20.0
                    initial := Txt{text: "?" draw_text.color: #xffffff}
                    pic := Image{visible: false width: 40 height: 40 fit: ImageFit.CropToFill draw_bg.border_radius: 20.0}}
                info := View{width: 220 height: Fit flow: Down spacing: 2
                    top := View{width: Fill height: Fit flow: Right spacing: 6 align: Align{y: 0.5}
                        name := Txt{text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 10.0}}
                        timed_out := RoundedView{visible: false width: Fit height: Fit padding: Inset{left: 6 right: 6 top: 1 bottom: 1}
                            new_batch: true draw_bg.color: #xf59e0b33 draw_bg.border_radius: 2.0
                            Txt{text: "Timed out" draw_text.color: #xfbbf24 draw_text.text_style.font_size: 7.5}}
                    }
                    sub := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 8.5}
                }
                chips := View{width: Fill height: Fit flow: Right spacing: 4 align: Align{y: 0.5}
                    c0 := RoleBadge{} c1 := RoleBadge{} c2 := RoleBadge{}
                    more := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 8.0}}
                actions := View{width: Fit height: Fit flow: Right spacing: 6
                    roles := SmallBtn{t.text: "Manage Roles"}
                    timeout := SmallBtn{t.text: "Timeout" t.draw_text.color: #xfbbf24}
                    kick := SmallBtn{t.text: "Kick" t.draw_text.color: #xf87171}
                    ban := SmallBtn{t.text: "Ban" t.draw_text.color: #xf87171}
                }
            }
            Empty := Hint{text: "No members match." margin: 8}
        }
    }

    // Rails' emoji row: 32px image, :name:, uploaded by; delete on the right.
    let EmojiCell = RoundedView{width: 380 height: Fit padding: Inset{left: 12 right: 8 top: 8 bottom: 8}
        flow: Right spacing: 12 align: Align{y: 0.5} new_batch: true
        draw_bg.color: gray_800 draw_bg.border_radius: 4.0
        img := Image{visible: false width: 32 height: 32 fit: ImageFit.Smallest}
        View{width: Fill height: Fit flow: Down spacing: 2
            name := Txt{text: "" draw_text.color: gray_200 draw_text.text_style: theme.font_code{font_size: 9.5}}
            by := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 8.0}}
        delete := SmallBtn{t.text: "Delete" t.draw_text.color: #xf87171}}
    // Rails' sticker card: 96px image box, name, description, creator.
    let StickerCell = RoundedView{width: 183 height: Fit padding: 12 flow: Down spacing: 4 align: Align{x: 0.5} new_batch: true
        draw_bg.color: gray_800 draw_bg.border_radius: 4.0
        View{width: Fill height: 96 align: Center
            img := Image{visible: false width: 96 height: 96 fit: ImageFit.Smallest}}
        name := Txt{text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 9.5}}
        desc := Txt{width: Fit text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 8.5}
        by := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 8.0}
        delete := SmallBtn{t.text: "Delete" t.draw_text.color: #xf87171}}

    mod.widgets.CustomListBase = #(lists::CustomList::register_widget(vm))
    mod.widgets.CustomList = set_type_default() do mod.widgets.CustomListBase{
        width: Fill height: 420
        stickers: false
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Row := View{width: Fill height: Fit flow: Right spacing: 8 margin: Inset{bottom: 8}
                i0 := EmojiCell{} i1 := EmojiCell{} i2 := View{visible: false} i3 := View{visible: false}}
            Empty := View{width: Fill height: Fit padding: Inset{top: 32 bottom: 32} align: Align{x: 0.5}
                Txt{text: "No custom emojis yet" draw_text.color: gray_500}}
        }
    }
    mod.widgets.StickerList = mod.widgets.CustomList{
        stickers: true
        list +: {
            Row := View{width: Fill height: Fit flow: Right spacing: 12 margin: Inset{bottom: 12}
                i0 := StickerCell{} i1 := StickerCell{} i2 := StickerCell{} i3 := StickerCell{}}
            Empty := View{width: Fill height: Fit padding: Inset{top: 32 bottom: 32} align: Align{x: 0.5}
                Txt{text: "No stickers yet" draw_text.color: gray_500}}
        }
    }

    mod.widgets.AuditListBase = #(lists::AuditList::register_widget(vm))
    mod.widgets.AuditList = set_type_default() do mod.widgets.AuditListBase{
        width: Fill height: 640
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Entry := RoundedView{width: Fill height: Fit margin: Inset{bottom: 4} padding: Inset{left: 16 right: 16 top: 12 bottom: 12}
                flow: Right spacing: 12 align: Align{y: 0.5} new_batch: true
                draw_bg.color: gray_800 draw_bg.border_radius: 4.0
                badge := RoundedView{width: 32 height: 32 flow: Overlay align: Center new_batch: true draw_bg.border_radius: 16.0
                    edit := Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/edit.svg")}
                    user := Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/users.svg")}
                    ban := Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/user_x.svg")}
                    link := Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/link.svg")}}
                text := View{width: Fill height: Fit flow: Down spacing: 2
                    line := View{width: Fill height: Fit flow: Right spacing: 5
                        actor := Txt{text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 10.0}}
                        what := Txt{width: Fill text: "" draw_text.color: gray_300 draw_text.text_style.font_size: 10.0}}
                    when := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 8.5}}
            }
            Empty := Hint{text: "No audit log entries yet." margin: 8}
        }
    }

    mod.widgets.DiscoverListBase = #(lists::DiscoverList::register_widget(vm))
    mod.widgets.DiscoverList = set_type_default() do mod.widgets.DiscoverListBase{
        width: Fill height: 380
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Row := View{width: Fill height: Fit flow: Right spacing: 12 margin: Inset{bottom: 12}
                c0 := DiscoverCard{} c1 := DiscoverCard{} c2 := DiscoverCard{}}
            Empty := View{width: Fill height: Fit padding: Inset{top: 48 bottom: 48} align: Align{x: 0.5}
                text := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 10.5}}
        }
    }

    mod.widgets.ResultListBase = #(lists::ResultList::register_widget(vm))
    mod.widgets.ResultList = set_type_default() do mod.widgets.ResultListBase{
        width: Fill height: Fill
        list := PortalList{
            width: Fill height: Fill
            flow: Down
            Hit := RoundedView{
                width: Fill height: Fit
                margin: Inset{bottom: 8}
                padding: 10
                flow: Down spacing: 4
                cursor: MouseCursor.Hand
                new_batch: true
                draw_bg.color: gray_700
                draw_bg.border_radius: 6.0
                channel := Txt{text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 8.5}
                head := View{width: Fill height: Fit flow: Right spacing: 8 align: Align{y: 0.5}
                    author := Txt{text: "" draw_text.text_style.font_size: 10.0}
                    time := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 8.5}
                }
                body := Body{text: ""}
            }
            Empty := Hint{text: "No results." margin: 8}
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
                            // Home: DMs and friends. Badge = friend requests + unread DMs.
                            RailSlot{
                                View{width: 48 height: 48 flow: Overlay
                                    home_btn := RoundedView{width: 48 height: 48 align: Center
                                        cursor: MouseCursor.Hand new_batch: true
                                        draw_bg.color: gray_700
                                        draw_bg.border_radius: 16.0
                                        Ico{icon_walk: Walk{width: 24 height: 24} draw_icon.color: gray_300
                                            draw_icon.svg: crate_resource("self:resources/icons/home.svg")}
                                    }
                                    View{width: 48 height: 48 align: Align{x: 1.0 y: 1.0}
                                        home_badge := RoundedView{visible: false width: Fit height: 18 padding: Inset{left: 5 right: 5}
                                            align: Center new_batch: true
                                            draw_bg.color: accent draw_bg.border_radius: 9.0
                                            draw_bg.border_size: 2.0 draw_bg.border_color: gray_950
                                            count := Txt{text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 7.5}}}
                                    }
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
                        View{width: 240 height: Fill flow: Overlay
                        SolidView{
                            width: 240 height: Fill
                            flow: Down
                            draw_bg.color: gray_800

                            server_side := View{width: Fill height: Fill flow: Down
                            // Header: 48px, server name 16px semibold white, chevron.
                            server_header := View{
                                cursor: MouseCursor.Hand
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
                            }

                            // Home: Rails' _dm_sidebar.
                            dm_side := View{visible: false width: Fill height: Fill flow: Down
                                View{width: Fill height: 48 padding: Inset{left: 12 right: 8} flow: Right align: Align{y: 0.5}
                                    Txt{width: Fill text: "Direct Messages" draw_text.color: #xffffff
                                        draw_text.text_style: theme.font_bold{font_size: 10.5}}
                                    dm_add_friend := View{width: 32 height: 32 align: Center cursor: MouseCursor.Hand
                                        Ico{icon_walk: Walk{width: 18 height: 18} draw_icon.color: gray_400
                                            draw_icon.svg: crate_resource("self:resources/icons/user_plus.svg")}}
                                }
                                SolidView{width: Fill height: 1 draw_bg.color: gray_900}
                                View{width: Fill height: Fill flow: Down padding: Inset{left: 8 right: 8 top: 8}
                                    friends_link := RoundedView{width: Fill height: Fit padding: Inset{left: 10 right: 10 top: 8 bottom: 8}
                                        margin: Inset{bottom: 2}
                                        flow: Right spacing: 12 align: Align{y: 0.5} cursor: MouseCursor.Hand new_batch: true
                                        draw_bg.color: #0000 draw_bg.border_radius: 4.0
                                        Ico{icon_walk: Walk{width: 20 height: 20} draw_icon.color: gray_400
                                            draw_icon.svg: crate_resource("self:resources/icons/users.svg")}
                                        label := Txt{text: "Friends" draw_text.color: gray_400 draw_text.text_style: theme.font_bold{font_size: 10.5}}
                                    }
                                    saved_link := RoundedView{width: Fill height: Fit padding: Inset{left: 10 right: 10 top: 8 bottom: 8}
                                        margin: Inset{bottom: 8}
                                        flow: Right spacing: 12 align: Align{y: 0.5} cursor: MouseCursor.Hand new_batch: true
                                        draw_bg.color: #0000 draw_bg.border_radius: 4.0
                                        Ico{icon_walk: Walk{width: 20 height: 20} draw_icon.color: gray_400
                                            draw_icon.svg: crate_resource("self:resources/icons/pin.svg")}
                                        label := Txt{text: "Saved Messages" draw_text.color: gray_400 draw_text.text_style: theme.font_bold{font_size: 10.5}}
                                    }
                                    dms := mod.widgets.DmList{}
                                }
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
                                me_avatar := RoundedView{flow: Overlay width: 32 height: 32 align: Center new_batch: true
                                    draw_bg.color: #x7f1d1d draw_bg.border_radius: 16.0
                                    me_initial := Txt{text: "" draw_text.text_style.font_size: 10.0}
                                    pic := Image{width: 32 height: 32 fit: ImageFit.CropToFill draw_bg.border_radius: 16.0}}
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
                        // Server dropdown (Rails: absolute left-2 right-2 top-12,
                        // gray-900, 1px gray-700 border, radius 8, py/px 1.5).
                        View{width: Fill height: Fit padding: Inset{left: 8 right: 8 top: 48}
                            server_menu := RoundedView{
                                visible: false
                                width: Fill height: Fit
                                flow: Down
                                padding: 6
                                new_batch: true
                                draw_bg.color: gray_900
                                draw_bg.border_radius: 8.0
                                draw_bg.border_size: 1.0
                                draw_bg.border_color: gray_700
                                menu_create_channel := MenuItem{label.text: "Create Channel" icon.draw_icon.svg: crate_resource("self:resources/icons/plus.svg")}
                                menu_create_category := MenuItem{label.text: "Create Category" icon.draw_icon.svg: crate_resource("self:resources/icons/folder.svg")}
                                menu_server_settings := MenuItem{label.text: "Server Settings" icon.draw_icon.svg: crate_resource("self:resources/icons/gear.svg")}
                                menu_divider := SolidView{width: Fill height: 1 margin: Inset{top: 4 bottom: 4} draw_bg.color: gray_700}
                                menu_leave := MenuItem{label.text: "Leave Server" label.draw_text.color: #xf87171 icon.icon_walk: Walk{width: 0 height: 16}}
                                menu_invite := MenuItem{label.text: "Invite People" icon.draw_icon.svg: crate_resource("self:resources/icons/link.svg")}
                            }
                        }
                        }

                        View{width: Fill height: Fill flow: Down
                        // Rails' friend request bar: who wants to be friends,
                        // i/n with arrows, then accept, decline and ignore.
                        friend_bar := SolidView{
                            visible: false
                            width: Fill height: 44
                            padding: Inset{left: 12 right: 12}
                            flow: Right spacing: 10 align: Align{y: 0.5}
                            draw_bg.color: accent_15
                            fb_prev := View{width: Fit height: Fit padding: 4 cursor: MouseCursor.Hand
                                Txt{text: "‹" draw_text.color: gray_300 draw_text.text_style.font_size: 14.0}}
                            fb_avatar := RoundedView{width: 28 height: 28 align: Center new_batch: true
                                draw_bg.color: #x1e1c1b draw_bg.border_radius: 14.0
                                initial := Txt{text: "?" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 9.0}}}
                            fb_text := Txt{width: Fill text: "" draw_text.color: gray_100 draw_text.text_style.font_size: 10.0}
                            fb_count := Txt{text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                            fb_next := View{width: Fit height: Fit padding: 4 cursor: MouseCursor.Hand
                                Txt{text: "›" draw_text.color: gray_300 draw_text.text_style.font_size: 14.0}}
                            SolidView{width: 1 height: 24 draw_bg.color: gray_600}
                            fb_accept := FriendBtn{width: 30 height: 30 draw_bg.color: #x16a34a
                                Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/check.svg")}}
                            fb_decline := FriendBtn{width: 30 height: 30 draw_bg.color: #xdc2626
                                Ico{icon_walk: Walk{width: 16 height: 16} draw_icon.svg: crate_resource("self:resources/icons/close.svg")}}
                            fb_ignore := RoundedView{width: Fit height: 30 padding: Inset{left: 10 right: 10} align: Center
                                cursor: MouseCursor.Hand new_batch: true draw_bg.color: gray_700 draw_bg.border_radius: 4.0
                                Txt{text: "Ignore" draw_text.color: gray_300 draw_text.text_style.font_size: 9.0}}
                        }
                        View{width: Fill height: Fill flow: Overlay
                        // ── Friends page (Rails conversations#index) ──
                        friends_page := SolidView{
                            visible: false
                            width: Fill height: Fill
                            flow: Down
                            draw_bg.color: gray_700
                            View{width: Fill height: 48 padding: Inset{left: 16 right: 16} flow: Right spacing: 8 align: Align{y: 0.5}
                                Ico{icon_walk: Walk{width: 20 height: 20} draw_icon.color: gray_400
                                    draw_icon.svg: crate_resource("self:resources/icons/users.svg")}
                                Txt{text: "Contacts" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 12.0}}
                            }
                            View{width: Fill height: Fit padding: Inset{left: 16 right: 16 bottom: 8} flow: Right spacing: 4
                                tab_online := TabPill{label.text: "Online"}
                                tab_all := TabPill{label.text: "All"}
                                tab_pending := TabPill{label.text: "Pending"
                                    pending_badge := RoundedView{visible: false width: Fit height: 16 padding: Inset{left: 5 right: 5}
                                        align: Center new_batch: true draw_bg.color: accent draw_bg.border_radius: 8.0
                                        count := Txt{text: "" draw_text.color: #xffffff draw_text.text_style.font_size: 7.5}}}
                                tab_blocked := TabPill{label.text: "Blocked"}
                                tab_search := TabPill{draw_bg.color: #x16a34acc label.text: "Search" label.draw_text.color: #xffffff}
                            }
                            SolidView{width: Fill height: 1 draw_bg.color: gray_900}
                            find_box := View{visible: false width: Fill height: Fit flow: Down spacing: 4 padding: 16
                                Txt{text: "Find People" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 11.0}}
                                Hint{text: "Search by name or public key (npub or hex)."}
                                RoundedView{width: Fill height: 40 margin: Inset{top: 8} padding: Inset{left: 12 right: 12}
                                    flow: Right spacing: 8 align: Align{y: 0.5} new_batch: true
                                    draw_bg.color: gray_900 draw_bg.border_radius: 8.0 draw_bg.border_size: 1.0 draw_bg.border_color: gray_700
                                    Ico{icon_walk: Walk{width: 18 height: 18} draw_icon.color: gray_500
                                        draw_icon.svg: crate_resource("self:resources/icons/search.svg")}
                                    find_input := TextInput{width: Fill height: 36 empty_text: "Search by name or public key..."
                                        draw_bg +: {color: #0000 color_hover: #0000 color_focus: #0000 color_empty: #0000
                                            border_color: #0000 border_color_hover: #0000 border_color_focus: #0000 border_color_empty: #0000}
                                        draw_text +: {color: gray_100 color_empty: gray_500}}
                                }
                            }
                            View{width: Fill height: Fill padding: Inset{left: 16 right: 16}
                                friend_list := mod.widgets.FriendList{}
                            }
                        }

                        // ── Chat column ──
                        chat_col := View{
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
                                topic_divider := SolidView{width: 1 height: 24 margin: Inset{left: 8 right: 8} draw_bg.color: gray_600}
                                // Topics are one line: truncate, don't wrap (Rails: truncate).
                                channel_topic := Txt{width: Fill text: "" draw_text.color: gray_400
                                    flow: Flow.Right{wrap: false} text_overflow: TextOverflow.Ellipsis}
                                pins_btn := View{width: Fit height: Fit cursor: MouseCursor.Hand
                                    Ico{draw_icon.svg: crate_resource("self:resources/icons/pin.svg")}}
                                invite_btn := View{width: Fit height: Fit cursor: MouseCursor.Hand
                                    Ico{draw_icon.svg: crate_resource("self:resources/icons/users.svg")}}
                                // Rails: bg-gray-900 rounded h-7, 200px.
                                search_bar := RoundedView{width: 200 height: 28 padding: Inset{left: 4 right: 8}
                                    align: Align{y: 0.5} new_batch: true
                                    draw_bg.color: gray_900 draw_bg.border_radius: 4.0
                                    search_input := TextInput{width: Fill height: 28 empty_text: "Search"
                                        draw_bg +: {color: #0000 color_hover: #0000 color_focus: #0000 color_empty: #0000
                                            border_color: #0000 border_color_hover: #0000 border_color_focus: #0000 border_color_empty: #0000}
                                        draw_text +: {color: gray_200 color_empty: gray_500}
                                    }
                                    Ico{icon_walk: Walk{width: 14 height: 14} draw_icon.color: gray_500
                                        draw_icon.svg: crate_resource("self:resources/icons/search.svg")}
                                }
                            }
                            SolidView{width: Fill height: 1 draw_bg.color: accent_12}

                            msg_area := View{
                                width: Fill height: Fill
                                flow: Overlay
                                messages := mod.widgets.MessageList{}
                                // Search filter hints (Rails: right-aligned, w-72, gray-900).
                                suggest_slot := View{
                                    width: Fill height: Fit
                                    align: Align{x: 1.0}
                                    padding: Inset{right: 16 top: 4}
                                    search_suggest := RoundedView{
                                        visible: false
                                        width: 288 height: Fit
                                        flow: Down
                                        padding: Inset{top: 6 bottom: 6 left: 6 right: 6}
                                        new_batch: true
                                        draw_bg.color: gray_900
                                        draw_bg.border_radius: 8.0
                                        draw_bg.border_size: 1.0
                                        draw_bg.border_color: gray_700
                                        Txt{text: "SEARCH FILTERS" margin: Inset{left: 6 top: 2 bottom: 4} draw_text.color: gray_500
                                            draw_text.text_style: theme.font_bold{font_size: 8.0}}
                                        f_from := MenuItem{label.text: "From a specific user   from: user" icon.icon_walk: Walk{width: 0 height: 16}}
                                        f_in := MenuItem{label.text: "In a specific channel   in: channel" icon.icon_walk: Walk{width: 0 height: 16}}
                                        f_has := MenuItem{label.text: "Has a specific type   has: file, image, or link" icon.icon_walk: Walk{width: 0 height: 16}}
                                        f_date := MenuItem{label.text: "Date filters   before:, after:, or on: date" icon.icon_walk: Walk{width: 0 height: 16}}
                                        f_pinned := MenuItem{label.text: "Pinned messages   pinned: true" icon.icon_walk: Walk{width: 0 height: 16}}
                                    }
                                }
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
                                // Rails' picker: above the composer's right end.
                                View{width: Fill height: Fill align: Align{x: 1.0 y: 1.0} padding: Inset{right: 16 bottom: 4}
                                    composer_picker := PickerPanel{}
                                }
                                // Rails' message request: the messages stay hidden
                                // behind a card until accepted.
                                dm_request := SolidView{
                                    visible: false
                                    width: Fill height: Fill
                                    align: Center
                                    draw_bg.color: gray_700
                                    RoundedView{width: 384 height: Fit flow: Down spacing: 6 padding: 24 align: Align{x: 0.5}
                                        new_batch: true
                                        draw_bg.color: gray_800 draw_bg.border_radius: 12.0
                                        draw_bg.border_size: 1.0 draw_bg.border_color: gray_700
                                        req_avatar := RoundedView{width: 64 height: 64 align: Center new_batch: true
                                            draw_bg.color: gray_600 draw_bg.border_radius: 32.0
                                            initial := Txt{text: "?" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 18.0}}}
                                        req_name := Txt{text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 13.0}}
                                        RoundedView{width: Fill height: Fit padding: 12 margin: Inset{top: 6 bottom: 6} new_batch: true
                                            draw_bg.color: #xeab3081a draw_bg.border_radius: 8.0
                                            Txt{width: Fill text: "This person is not in your contacts. Messages are hidden until you accept. Images and links are blocked for your safety."
                                                draw_text.color: gray_300 draw_text.text_style.font_size: 8.5}}
                                        req_waiting := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 8.5}
                                        View{width: Fit height: Fit flow: Right spacing: 8 margin: Inset{top: 8}
                                            req_accept := RoundedView{width: Fit height: 34 padding: Inset{left: 16 right: 16} align: Center
                                                cursor: MouseCursor.Hand new_batch: true draw_bg.color: #x16a34a draw_bg.border_radius: 4.0
                                                Txt{text: "Accept" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 9.5}}}
                                            req_decline := RoundedView{width: Fit height: 34 padding: Inset{left: 16 right: 16} align: Center
                                                cursor: MouseCursor.Hand new_batch: true draw_bg.color: gray_600 draw_bg.border_radius: 4.0
                                                Txt{text: "Decline" draw_text.color: gray_200 draw_text.text_style: theme.font_bold{font_size: 9.5}}}
                                        }
                                    }
                                }
                            }

                            // Typing row (24px) then the composer.
                            View{width: Fill height: 24 padding: Inset{left: 16} align: Align{y: 0.5}
                                notice := Txt{width: Fill text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                            }
                            // Rails: px-4 pb-4. The shell below takes 8 of that for
                            // the focus glow, which spills outside the bar.
                            composer_box := View{
                                width: Fill height: Fit
                                flow: Down
                                padding: Inset{left: 8 right: 8 bottom: 8}
                                View{width: Fill height: Fit flow: Down padding: Inset{left: 8 right: 8}
                                    reply_bar := ComposerBar{draw_bg.edge: 1.0 lead.text: "Replying to"}
                                    edit_bar := ComposerBar{lead.text: "✎" lead.draw_text.color: accent_light
                                        who.text: "Editing message"}
                                    spoiler_bar := ComposerBar{lead.text: "This message will be sent as a spoiler"
                                        lead.draw_text.color: gray_300}
                                }
                                // Rails' input bar: gray-600, radius 8, 1px accent/.2
                                // border; focused, the border goes to accent/.5 with a
                                // 2px accent/.12 ring and a 20px accent/.1 glow, 0.25s.
                                composer_shell := View{
                                    width: Fill height: Fit
                                    padding: 8
                                    show_bg: true
                                    new_batch: true
                                    draw_bg +: {
                                        focus: instance(0.0)
                                        fill: uniform(gray_600)
                                        edge: uniform(accent_20)
                                        edge_focus: uniform(accent_50)
                                        glow: uniform(accent)
                                        pixel: fn() {
                                            let p = self.pos * self.rect_size
                                            let c = self.rect_size * 0.5
                                            // Distance to the bar: a rect inset 8px, radius 8.
                                            let q = abs(p - c) - (c - vec2(8.0, 8.0)) + vec2(8.0, 8.0)
                                            let d = length(max(q, vec2(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - 8.0
                                            let border = mix(self.edge, self.edge_focus, self.focus)
                                            let inside = 1.0 - clamp(d + 0.5, 0.0, 1.0)
                                            let on_edge = clamp(d + 1.5, 0.0, 1.0) * inside
                                            let body = mix(self.fill.rgb, border.rgb, on_edge * border.a)
                                            let ring = (1.0 - smoothstep(0.5, 2.5, d)) * 0.12
                                            let halo = exp(-max(d, 0.0) / 7.0) * 0.1
                                            let out_a = (ring + halo) * self.focus * (1.0 - inside)
                                            return vec4(body * inside + self.glow.rgb * out_a, inside + out_a)
                                        }
                                    }
                                    animator: Animator{
                                        focus: {
                                            default: @off
                                            off: AnimatorState{from: {all: Forward {duration: 0.25}} apply: {draw_bg: {focus: 0.0}}}
                                            on: AnimatorState{from: {all: Forward {duration: 0.25}} apply: {draw_bg: {focus: 1.0}}}
                                        }
                                    }
                                    View{
                                        width: Fill height: Fit
                                        padding: Inset{left: 8 right: 8}
                                        flow: Right
                                        align: Align{y: 0.5}
                                        attach_btn := ComposerBtn{ico.draw_icon.svg: crate_resource("self:resources/icons/plus.svg")}
                                        // Rails: text-sm leading-6, py-2 px-1, up to max-h-48.
                                        composer := mod.widgets.RichInput{
                                            width: Fill height: Fit{max: FitBound.Abs(192)}
                                            padding: Inset{left: 4 right: 4 top: 8 bottom: 8}
                                            is_multiline: true
                                            submit_on_enter: true
                                            highlight: true
                                            empty_text: "Message #general"
                                            draw_bg +: {pixel: fn() { return vec4(0.0, 0.0, 0.0, 0.0) }}
                                            draw_text +: {color: gray_100 color_empty: gray_400
                                                text_style +: {font_size: 10.5 line_spacing: 1.5}}
                                        }
                                        spoiler_btn := ComposerBtn{ico.draw_icon.svg: crate_resource("self:resources/icons/eye_off.svg")}
                                        emoji_btn := ComposerBtn{ico.draw_icon.svg: crate_resource("self:resources/icons/smile.svg")}
                                        send_btn := ComposerBtn{ico.draw_icon.svg: crate_resource("self:resources/icons/send.svg")}
                                    }
                                }
                            }
                        }

                        }
                        }

                        // ── Search results: 420px, gray-800 (spec), in place of members ──
                        search_panel := SolidView{
                            visible: false
                            width: 420 height: Fill
                            flow: Down
                            padding: Inset{left: 12 right: 12 top: 0 bottom: 12}
                            draw_bg.color: gray_800
                            View{width: Fill height: 48 flow: Right spacing: 8 align: Align{y: 0.5}
                                Txt{text: "Results" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 11.0}}
                                search_count := Txt{width: Fill text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 9.0}
                                close_search := View{width: Fit height: Fit padding: 6 cursor: MouseCursor.Hand
                                    Ico{icon_walk: Walk{width: 14 height: 14} draw_icon.svg: crate_resource("self:resources/icons/close.svg")}}
                            }
                            search_results := mod.widgets.ResultList{}
                        }
                        // ── Member list: 240px, gray-800, 1px accent/.15 left border ──
                        member_edge := SolidView{width: 1 height: Fill draw_bg.color: accent_15}
                        member_col := SolidView{
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
                            nav_appearance := NavItem{label.text: "Appearance"}
                            nav_relays := NavItem{label.text: "Relays"}
                        }
                        settings_pages := ScrollYView{
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

                            // One card: what others see, edited in place (Rails had an
                            // editable banner card, a separate preview card and a
                            // colour preview strip; this is all three).
                            page_profile := View{
                                visible: false
                                width: 768 height: Fit flow: Down
                                PageTitle{text: "Profile"}
                                Hint{text: "This is how others see you. Click the banner or your picture to change them."
                                    margin: Inset{bottom: 12}}
                                profile_editor := RoundedView{
                                    width: 480 height: Fit flow: Down
                                    new_batch: true
                                    draw_bg +: {
                                        c0: uniform(vec4(0.118 0.11 0.106 1.))
                                        c1: uniform(vec4(0.118 0.11 0.106 1.))
                                        banner: uniform(vec4(0.17 0.16 0.16 1.))
                                        pixel: fn() {
                                            let sdf = Sdf2d.viewport(self.pos * self.rect_size)
                                            sdf.box(0. 0. self.rect_size.x self.rect_size.y 8.0)
                                            let t = clamp((self.pos.x + self.pos.y) * 0.5, 0.0, 1.0)
                                            let body = mix(self.c0, self.c1, t)
                                            let px = self.pos.y * self.rect_size.y
                                            sdf.fill(mix(self.banner, body, step(128.0, px)))
                                            return sdf.result
                                        }
                                    }
                                    // Rails: h-32 banner.
                                    ed_banner := View{width: Fill height: 128 flow: Overlay cursor: MouseCursor.Hand
                                        align: Align{x: 1.0 y: 1.0}
                                        ed_banner_img := Image{visible: false width: Fill height: 128 fit: ImageFit.CropToFill
                                            draw_bg.border_radius: 8.0}
                                        RoundedView{width: Fit height: Fit margin: 8 padding: Inset{left: 8 right: 8 top: 4 bottom: 4}
                                            new_batch: true draw_bg.color: #x00000080 draw_bg.border_radius: 4.0
                                            Txt{text: "Change banner" draw_text.color: #xffffffcc draw_text.text_style.font_size: 8.5}}
                                    }
                                    View{width: Fill height: Fit flow: Down padding: Inset{left: 16 right: 16 bottom: 16}
                                        margin: Inset{top: -44}
                                        // Rails: 80px avatar with a 4px ring.
                                        ed_avatar := RoundedView{width: 88 height: 88 padding: 4 cursor: MouseCursor.Hand
                                            new_batch: true draw_bg.color: #x1e1c1b draw_bg.border_radius: 44.0
                                            ed_face := RoundedView{flow: Overlay width: 80 height: 80 align: Center new_batch: true
                                                draw_bg.color: #x1e1c1b draw_bg.border_radius: 40.0
                                                initial := Txt{text: "?" draw_text.color: #xffffff
                                                    draw_text.text_style: theme.font_bold{font_size: 20.0}}
                                                pic := Image{visible: false width: 80 height: 80 fit: ImageFit.CropToFill
                                                    draw_bg.border_radius: 40.0}
                                            }
                                        }
                                        RoundedView{width: Fill height: Fit flow: Down spacing: 6 padding: 12 margin: Inset{top: 8}
                                            new_batch: true draw_bg.color: #x0000004d draw_bg.border_radius: 8.0
                                            p_display := CardInput{empty_text: "Display name"
                                                draw_text +: {text_style: theme.font_bold{font_size: 13.0}}}
                                            p_username := CardInput{empty_text: "username"
                                                draw_text +: {color: #xffffff99 text_style +: {font_size: 9.0}}}
                                            View{width: Fill height: Fit flow: Right spacing: 6 align: Align{y: 0.5}
                                                p_status_emoji := RoundedView{width: 32 height: 32 align: Center cursor: MouseCursor.Hand
                                                    new_batch: true draw_bg.color: #x00000040 draw_bg.border_radius: 6.0
                                                    flow: Overlay
                                                    label := Txt{text: "🙂" draw_text.text_style.font_size: 12.0}
                                                    img := Image{visible: false width: 20 height: 20 fit: ImageFit.Smallest}}
                                                p_status := CardInput{empty_text: "What are you up to?"
                                                    draw_text +: {color: #xffffffb3 text_style +: {font_size: 9.5}}}
                                            }
                                            SolidView{width: Fill height: 1 draw_bg.color: #xffffff1a}
                                            CardHead{text: "ABOUT ME"}
                                            p_about := CardInput{empty_text: "Tell others about yourself" is_multiline: true
                                                height: Fit{min: 48}
                                                draw_text +: {color: #xffffffcc text_style +: {font_size: 9.5}}}
                                        }
                                    }
                                }
                                FieldLabel{text: "PROFILE THEME"}
                                View{width: 480 height: Fit flow: Right spacing: 8 align: Align{y: 0.5}
                                    p_color := TextInput{width: 120 height: 36 empty_text: "#1e1c1b"}
                                    p_color_2 := TextInput{width: 120 height: 36 empty_text: "#1e1c1b"}
                                    Hint{width: Fit text: "Two colours make a gradient."}
                                }
                                View{width: 480 height: Fit margin: Inset{top: 20} flow: Right spacing: 12 align: Align{y: 0.5}
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
                        // Appearance: Rails clears the overlay so the app shows
                        // through and puts the picker in a bar along the bottom.
                        page_appearance := View{
                            visible: false
                            width: Fill height: Fill
                            align: Align{x: 0.5 y: 1.0}
                            View{
                                width: Fill height: Fit
                                align: Align{x: 0.5}
                                padding: Inset{left: 40 right: 40 top: 40 bottom: 20}
                                show_bg: true
                                draw_bg +: {
                                    pixel: fn() {
                                        // black/80 at the bottom, /60 midway, clear at the top.
                                        let t = self.pos.y
                                        let a = mix(0.0, 0.6, clamp(t * 2.0, 0.0, 1.0))
                                        return vec4(0.0, 0.0, 0.0, mix(a, 0.8, clamp(t * 2.0 - 1.0, 0.0, 1.0)))
                                    }
                                }
                                View{width: 768 height: Fit flow: Down
                                    Txt{text: "THEME" margin: Inset{bottom: 12} draw_text.color: #xffffffb3
                                        draw_text.text_style: theme.font_bold{font_size: 8.5}}
                                    View{width: Fill height: Fit flow: Right{wrap: true} spacing: 8 margin: Inset{bottom: 16}
                                    th_inferno := ThemeTile{label.text: "Inferno" swatch +: {draw_bg +: {c0: #x1e1c1b c1: #x2c2a29 c2: #xdc2626}}}
                                    th_frostfire := ThemeTile{label.text: "Frostfire" swatch +: {draw_bg +: {c0: #x0f1b2d c1: #x243b53 c2: #x3b82f6}}}
                                    th_boron := ThemeTile{label.text: "Boron" swatch +: {draw_bg +: {c0: #x0f1f15 c1: #x1a3328 c2: #x10b981}}}
                                    th_brimstone := ThemeTile{label.text: "Brimstone" swatch +: {draw_bg +: {c0: #x1a1025 c1: #x2d1f42 c2: #xa855f7}}}
                                    th_plasma := ThemeTile{label.text: "Plasma" swatch +: {draw_bg +: {c0: #x1c0f1c c1: #x3d2438 c2: #xec4899}}}
                                    th_pulsar := ThemeTile{label.text: "Pulsar" swatch +: {draw_bg +: {c0: #x1e141e c1: #x3e2a3c c2: #xf9a8d4}}}
                                    th_obsidian := ThemeTile{label.text: "Obsidian" swatch +: {draw_bg +: {c0: #x111827 c1: #x1e293b c2: #x94a3b8}}}
                                    }
                                    // Rails: full-width confirm gradient, py-2.5, semibold.
                                    theme_save := RoundedView{width: Fill height: 40 align: Align{x: 0.5 y: 0.5}
                                        cursor: MouseCursor.Hand new_batch: true
                                        draw_bg.color: confirm draw_bg.border_radius: 4.0
                                        Txt{text: "Save Changes" draw_text.color: #xffffff
                                            draw_text.text_style: theme.font_bold{font_size: 10.0}}
                                    }
                                }
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

                    // Create / edit channel: a page, as in Rails (channels/new,
                    // channels/edit): centered max-w-lg on gray-950.
                    channel_page := SolidView{
                        visible: false
                        width: Fill height: Fill
                        align: Align{x: 0.5}
                        draw_bg.color: gray_950
                        ScrollYView{width: 512 height: Fill flow: Down padding: Inset{top: 48 bottom: 48}
                            ch_title := Txt{text: "Create Channel" draw_text.color: #xffffff
                                draw_text.text_style: theme.font_bold{font_size: 15.0}}
                            ch_subtitle := Txt{text: "" margin: Inset{top: 2 bottom: 20} draw_text.color: gray_500 draw_text.text_style.font_size: 10.0}
                            Card{
                                create_only := View{width: Fill height: Fit flow: Right spacing: 12
                                    View{width: Fill height: Fit flow: Down
                                        FieldLabel{text: "TYPE" margin: Inset{bottom: 6}}
                                        ch_type := DropDown{width: Fill labels: ["Text", "Voice"]}
                                    }
                                    View{width: Fill height: Fit flow: Down
                                        FieldLabel{text: "CATEGORY" margin: Inset{bottom: 6}}
                                        ch_category := DropDown{width: Fill labels: ["None"]}
                                    }
                                }
                                FieldLabel{text: "CHANNEL NAME"}
                                ch_name := Field{empty_text: "new-channel"}
                                FieldLabel{text: "TOPIC"}
                                ch_topic := Field{empty_text: "What's this channel about?"}
                            }
                            Card{
                                ch_nsfw := CheckBox{text: "Age-Restricted Channel (NSFW)"}
                                ch_post_only := CheckBox{text: "Post-only (only moderators can post)"}
                                ch_encrypted := CheckBox{text: "End-to-End Encryption"}
                                ch_roles_box := View{width: Fill height: Fit flow: Down
                                    FieldLabel{text: "ALLOWED ROLES"}
                                    Hint{text: "Besides the owner and admins. Choose Everyone for all members."}
                                    ch_roles := mod.widgets.RolePicker{}
                                }
                            }
                            View{width: Fill height: Fit flow: Right spacing: 12 align: Align{y: 0.5}
                                ch_cancel := View{width: Fit height: Fit padding: 8 cursor: MouseCursor.Hand
                                    Txt{text: "Cancel" draw_text.color: gray_400}}
                                View{width: Fill height: 1}
                                ch_save := Button{text: "Create Channel"}
                            }
                            ch_danger := Card{margin: Inset{top: 24}
                                Txt{text: "Danger Zone" draw_text.color: #xf87171 draw_text.text_style: theme.font_bold{font_size: 11.0}}
                                Hint{text: "Deleting a channel removes it for everyone. Its messages can't be shown again."}
                                ch_delete := Button{text: "Delete Channel" margin: Inset{top: 8}}
                            }
                        }
                    }

                    // Create / edit category: Rails' max-w-md card, name only.
                    category_page := SolidView{
                        visible: false
                        width: Fill height: Fill
                        align: Align{x: 0.5 y: 0.3}
                        draw_bg.color: gray_950
                        RoundedView{width: 448 height: Fit flow: Down spacing: 4 padding: 32 new_batch: true
                            draw_bg.color: gray_800 draw_bg.border_radius: 8.0
                            cat_title := Txt{text: "Create Category" draw_text.color: #xffffff
                                draw_text.text_style: theme.font_bold{font_size: 15.0}}
                            FieldLabel{text: "NAME"}
                            cat_name := Field{empty_text: "New category"}
                            View{width: Fill height: Fit margin: Inset{top: 16} flow: Right spacing: 12 align: Align{y: 0.5}
                                cat_cancel := View{width: Fit height: Fit padding: 8 cursor: MouseCursor.Hand
                                    Txt{text: "Cancel" draw_text.color: gray_400}}
                                View{width: Fill height: 1}
                                cat_save := Button{text: "Create Category"}
                            }
                        }
                    }

                    // Server settings: Rails' full-page layout (w-56 nav,
                    // max-w-3xl content, round close), gated per page.
                    srv_settings := SolidView{
                        visible: false
                        width: Fill height: Fill
                        flow: Right
                        draw_bg.color: gray_900
                        SolidView{
                            width: 224 height: Fill
                            flow: Down spacing: 2
                            padding: Inset{left: 16 right: 16 top: 24}
                            draw_bg.color: gray_800
                            srv_nav_title := NavHeader{text: "SERVER"}
                            snav_overview := NavItem{label.text: "Overview"}
                            expression_hdr := NavHeader{text: "EXPRESSION"}
                            snav_emoji := NavItem{label.text: "Emoji"}
                            snav_stickers := NavItem{label.text: "Stickers"}
                            people_hdr := NavHeader{text: "PEOPLE"}
                            snav_members := NavItem{label.text: "Members"}
                            snav_roles := NavItem{label.text: "Roles"}
                            snav_invites := NavItem{label.text: "Invites"}
                            moderation_hdr := NavHeader{text: "MODERATION"}
                            snav_audit := NavItem{label.text: "Audit Log"}
                            snav_bans := NavItem{label.text: "Bans"}
                            SolidView{width: Fill height: 1 margin: Inset{top: 16 bottom: 8} draw_bg.color: gray_700}
                            snav_delete := NavItem{label.text: "Delete Server" label.draw_text.color: #xf87171}
                        }
                        ScrollYView{
                            width: Fill height: Fill
                            flow: Down
                            padding: Inset{left: 40 right: 40 top: 32 bottom: 32}

                            // Rails' server profile: the form, and beside it the
                            // card people see on invites, updated as you type.
                            spage_overview := View{
                                width: Fill height: Fit flow: Right spacing: 32
                                View{width: Fill height: Fit flow: Down
                                    PageTitle{text: "Server Profile" margin: Inset{bottom: 2}}
                                    Hint{text: "Customize how your server appears in invite links"}
                                    FieldLabel{text: "NAME"}
                                    so_name := Field{}
                                    FieldLabel{text: "DESCRIPTION"}
                                    so_about := TextInput{width: Fill height: Fit{min: 64} is_multiline: true empty_text: "What's this server about?"}
                                    Divider{}
                                    FieldLabel{text: "ICON" margin: Inset{bottom: 2}}
                                    Hint{text: "We recommend an image of at least 512x512." margin: Inset{bottom: 10}}
                                    View{width: Fill height: Fit flow: Right spacing: 12 align: Align{y: 0.5}
                                        so_icon_pick := Button{text: "Change Server Icon"}
                                        so_icon_remove := LinkBtn{label.text: "Remove Icon"}
                                    }
                                    Divider{}
                                    FieldLabel{text: "BANNER" margin: Inset{bottom: 2}}
                                    Hint{text: "Recommended size: 960x540. Shown on your invite page." margin: Inset{bottom: 10}}
                                    View{width: Fill height: Fit flow: Right spacing: 12 align: Align{y: 0.5}
                                        so_banner_pick := Button{text: "Upload Banner"}
                                        so_banner_remove := LinkBtn{label.text: "Remove Banner"}
                                    }
                                    Divider{}
                                    // Flutter's catalog tag.
                                    FieldLabel{text: "SERVER TYPE" margin: Inset{bottom: 2}}
                                    Hint{text: "Shown as a tag in server discovery." margin: Inset{bottom: 8}}
                                    so_type := DropDown{width: 240 labels: ["Community", "Friends & Family", "Gaming", "Work & Team", "18+"]}
                                    FieldLabel{text: "SERVER CONFIGURATION"}
                                    so_discoverable := CheckBox{text: "Public server"}
                                    Hint{margin: Inset{left: 13 bottom: 8} text: "Anyone can discover and join this server through connected relays. When disabled, users need an invite link."}
                                    so_age := CheckBox{text: "Age restricted (18+)"}
                                    Hint{margin: Inset{left: 13} text: "Members must confirm they are 18+ to join."}
                                    Divider{}
                                    FieldLabel{text: "WELCOME MESSAGE"}
                                    so_welcome_on := CheckBox{text: "Send a welcome message when someone joins"}
                                    FieldLabel{text: "WELCOME CHANNEL"}
                                    so_welcome_ch := DropDown{width: Fill labels: ["Default (first text channel)"]}
                                    FieldLabel{text: "MESSAGE TEMPLATE"}
                                    so_welcome := Field{empty_text: "Welcome to the server, {user}!"}
                                    Hint{margin: Inset{top: 4} text: "Use {user} for display name, {tag} for username, {server} for server name"}
                                    View{width: Fill height: Fit margin: Inset{top: 24} flow: Right spacing: 12 align: Align{y: 0.5}
                                        so_save := Button{text: "Save Changes"}
                                        so_note := Hint{text: ""}
                                    }
                                }
                                View{width: 288 height: Fit flow: Down
                                    FieldLabel{text: "PREVIEW" margin: Inset{top: 4 bottom: 10}}
                                    RoundedView{width: 288 height: Fit flow: Down new_batch: true
                                        draw_bg.color: gray_950 draw_bg.border_radius: 8.0
                                        View{width: Fill height: 112 flow: Overlay
                                            RoundedView{width: Fill height: 112 draw_bg.color: gray_700 draw_bg.border_radius: 8.0}
                                            sp_banner := Image{visible: false width: Fill height: 112 fit: ImageFit.CropToFill draw_bg.border_radius: 8.0}
                                        }
                                        View{width: Fill height: Fit flow: Down padding: Inset{left: 16 right: 16 bottom: 16} margin: Inset{top: -32}
                                            RoundedView{width: 72 height: 72 padding: 4 new_batch: true
                                                draw_bg.color: gray_950 draw_bg.border_radius: 10.0
                                                sp_icon := RoundedView{width: 64 height: 64 flow: Overlay align: Center new_batch: true
                                                    draw_bg.color: gray_700 draw_bg.border_radius: 8.0
                                                    initial := Txt{text: "?" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 15.0}}
                                                    pic := Image{visible: false width: 64 height: 64 fit: ImageFit.CropToFill draw_bg.border_radius: 8.0}
                                                }
                                            }
                                            sp_name := Txt{margin: Inset{top: 8} text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 10.5}}
                                            sp_about := Txt{width: Fill margin: Inset{top: 2} text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                                            View{width: Fill height: Fit margin: Inset{top: 6} flow: Right spacing: 6 align: Align{y: 0.5}
                                                RoundedView{width: 8 height: 8 draw_bg.color: gray_500 draw_bg.border_radius: 4.0}
                                                sp_members := Txt{text: "" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                                                sp_type := RoundedView{width: Fit height: Fit padding: Inset{left: 6 right: 6 top: 2 bottom: 2} new_batch: true
                                                    draw_bg.color: gray_800 draw_bg.border_radius: 4.0
                                                    label := Txt{text: "" draw_text.color: gray_300 draw_text.text_style.font_size: 8.0}}
                                                sp_age := RoundedView{visible: false width: Fit height: Fit padding: Inset{left: 6 right: 6 top: 2 bottom: 2} new_batch: true
                                                    draw_bg.color: #xef444426 draw_bg.border_radius: 4.0
                                                    Txt{text: "18+" draw_text.color: #xf87171 draw_text.text_style.font_size: 8.0}}
                                            }
                                        }
                                    }
                                }
                            }

                            // Rails' invites page: generate with limits, then the
                            // active list with copy and revoke.
                            spage_invites := View{
                                visible: false
                                width: 768 height: Fit flow: Down
                                PageTitle{text: "Invites" margin: Inset{bottom: 16}}
                                Card{
                                    Txt{text: "GENERATE A NEW INVITE" draw_text.color: gray_300 draw_text.text_style: theme.font_bold{font_size: 9.0}}
                                    View{width: Fill height: Fit margin: Inset{top: 10} flow: Right spacing: 12 align: Align{y: 1.0}
                                        View{width: 180 height: Fit flow: Down spacing: 4
                                            Txt{text: "Expire After" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                                            inv_expires := DropDown{width: Fill labels: ["Never", "30 minutes", "1 hour", "6 hours", "12 hours", "1 day", "7 days"]}
                                        }
                                        View{width: 180 height: Fit flow: Down spacing: 4
                                            Txt{text: "Max Uses" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}
                                            inv_max := DropDown{width: Fill labels: ["Unlimited", "1 use", "5 uses", "10 uses", "25 uses", "50 uses", "100 uses"]}
                                        }
                                        inv_generate := Button{text: "Generate Invite"}
                                    }
                                }
                                inv_title := Txt{margin: Inset{top: 8 bottom: 8} text: "ACTIVE INVITES (0)" draw_text.color: gray_300 draw_text.text_style: theme.font_bold{font_size: 9.0}}
                                srv_invites := mod.widgets.PeopleList{
                                    list +: {Empty +: {text: "No active invites. Create one above to invite people to your server."}}
                                }
                            }

                            // Rails' role editor: list on the left; Display,
                            // Permissions and Members tabs; a save bar while
                            // anything is unsaved.
                            spage_roles := View{
                                visible: false
                                width: Fill height: Fit flow: Right spacing: 24
                                View{width: 240 height: Fit flow: Down
                                    View{width: Fill height: Fit flow: Right align: Align{y: 0.5} margin: Inset{bottom: 16}
                                        PageTitle{width: Fill text: "Roles" margin: 0}
                                        role_create := Button{text: "Create Role"}
                                    }
                                    role_list := mod.widgets.RoleList{height: 360}
                                    Hint{margin: Inset{top: 8} text: "Drag to reorder. Roles at or above your highest can't be edited."}
                                }
                                View{width: Fill height: Fit flow: Down
                                    View{width: Fill height: Fit flow: Right align: Align{y: 0.5} margin: Inset{bottom: 16}
                                        View{width: Fill height: Fit flow: Down spacing: 2
                                            Txt{text: "EDIT ROLE" draw_text.color: gray_500 draw_text.text_style: theme.font_bold{font_size: 8.0}}
                                            role_title := Txt{text: "" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 15.0}}
                                        }
                                        role_delete := Button{text: "Delete Role"}
                                    }
                                    role_locked := Hint{visible: false margin: Inset{bottom: 12} text: "This role is at or above your highest role, so you can't change it."}
                                    View{width: Fill height: Fit flow: Right spacing: 4 margin: Inset{bottom: 16}
                                        role_tab_display := TabPill{draw_bg.color: gray_600 label.text: "Display"}
                                        role_tab_perms := TabPill{label.text: "Permissions"}
                                        role_tab_members := TabPill{label.text: "Members"}
                                    }
                                    role_display := Card{
                                        role_fields := View{width: Fill height: Fit flow: Down
                                            FieldLabel{text: "ROLE NAME" margin: Inset{bottom: 6}}
                                            role_name := Field{empty_text: "Role name"}
                                            FieldLabel{text: "ROLE COLOR"}
                                            View{width: Fit height: Fit flow: Right spacing: 4 sw0 := Swatch{draw_bg.color: #x1abc9c} sw1 := Swatch{draw_bg.color: #x2ecc71} sw2 := Swatch{draw_bg.color: #x3498db} sw3 := Swatch{draw_bg.color: #x9b59b6} sw4 := Swatch{draw_bg.color: #xe91e63} sw5 := Swatch{draw_bg.color: #xf1c40f} sw6 := Swatch{draw_bg.color: #xe67e22} sw7 := Swatch{draw_bg.color: #xe74c3c} sw8 := Swatch{draw_bg.color: #x95a5a6} sw9 := Swatch{draw_bg.color: #x607d8b}}
                                            View{width: Fit height: Fit flow: Right spacing: 4 margin: Inset{top: 4 bottom: 12} sw10 := Swatch{draw_bg.color: #x11806a} sw11 := Swatch{draw_bg.color: #x1f8b4c} sw12 := Swatch{draw_bg.color: #x206694} sw13 := Swatch{draw_bg.color: #x71368a} sw14 := Swatch{draw_bg.color: #xad1457} sw15 := Swatch{draw_bg.color: #xc27c0e} sw16 := Swatch{draw_bg.color: #xa84300} sw17 := Swatch{draw_bg.color: #x992d22} sw18 := Swatch{draw_bg.color: #xffffff} sw19 := Swatch{draw_bg.color: #x99aab5}}
                                            View{width: Fill height: Fit flow: Right spacing: 10 align: Align{y: 0.5}
                                                role_swatch := RoundedView{width: 36 height: 36 draw_bg.color: #x99aab5 draw_bg.border_radius: 4.0}
                                                role_color := TextInput{width: 120 height: 36 empty_text: "#99aab5"}
                                            }
                                            SolidView{width: Fill height: 1 margin: Inset{top: 16 bottom: 8} draw_bg.color: gray_700_50}
                                            role_hoist := View{width: Fill height: Fit flow: Right align: Align{y: 0.5} padding: Inset{top: 8 bottom: 8} cursor: MouseCursor.Hand
                                                View{width: Fill height: Fit flow: Down spacing: 2
                                                    Txt{text: "Display separately" draw_text.color: #xffffff}
                                                    Hint{text: "Show members with this role in their own group in the member list"}}
                                                switch := Switch{}
                                            }
                                            role_mention := View{width: Fill height: Fit flow: Right align: Align{y: 0.5} padding: Inset{top: 8 bottom: 8} cursor: MouseCursor.Hand
                                                View{width: Fill height: Fit flow: Down spacing: 2
                                                    Txt{text: "Allow anyone to @mention this role" draw_text.color: #xffffff}
                                                    Hint{text: "Members without Mention Everyone can still ping it"}}
                                                switch := Switch{}
                                            }
                                            SolidView{width: Fill height: 1 margin: Inset{top: 8 bottom: 12} draw_bg.color: gray_700_50}
                                            FieldLabel{text: "PREVIEW" margin: Inset{bottom: 8}}
                                            RoundedView{width: Fill height: Fit flow: Down padding: 12 new_batch: true
                                                draw_bg.color: gray_900 draw_bg.border_radius: 4.0
                                                role_pv_group := Txt{text: "" draw_text.color: #x99aab5 draw_text.text_style: theme.font_bold{font_size: 7.5}}
                                                SolidView{width: Fill height: 1 margin: Inset{top: 8 bottom: 8} draw_bg.color: gray_700_50}
                                                role_pv_member := Txt{text: "" draw_text.color: #x99aab5 draw_text.text_style.font_size: 10.5}
                                                SolidView{width: Fill height: 1 margin: Inset{top: 8 bottom: 8} draw_bg.color: gray_700_50}
                                                View{width: Fill height: Fit flow: Right spacing: 8 align: Align{y: 0.5}
                                                    role_pv_msg := Txt{text: "" draw_text.color: #x99aab5 draw_text.text_style.font_size: 10.5}
                                                    Txt{text: "Today" draw_text.color: gray_500 draw_text.text_style.font_size: 9.0}
                                                }
                                                Txt{margin: Inset{top: 2} text: "This is a preview of how the role color looks in chat." draw_text.color: gray_300}
                                            }
                                        }
                                        role_everyone_note := Hint{visible: false text: "@everyone applies to every member. It has permissions only: no name, color or members of its own."}
                                    }
                                    role_perms_panel := Card{visible: false
                                        role_perms := mod.widgets.PermList{}
                                    }
                                    role_members_panel := Card{visible: false
                                        View{width: Fill height: Fit flow: Right align: Align{y: 0.5} margin: Inset{bottom: 10}
                                            Txt{width: Fill text: "MEMBERS" draw_text.color: gray_400 draw_text.text_style: theme.font_bold{font_size: 8.5}}
                                            role_member_count := Txt{text: "" draw_text.color: gray_500 draw_text.text_style.font_size: 9.0}
                                        }
                                        role_member_search := Field{empty_text: "Search members..."}
                                        role_members := mod.widgets.PeopleList{margin: Inset{top: 10} height: 420}
                                    }
                                }
                            }

                            // Rails' members page: search, a batch bar while
                            // some are selected, select all, the list.
                            spage_members := View{
                                visible: false
                                width: Fill height: Fit flow: Down
                                View{width: Fill height: Fit flow: Right spacing: 12 align: Align{y: 0.5} margin: Inset{bottom: 16}
                                    srv_members_title := PageTitle{width: Fill text: "Members" margin: 0}
                                    mem_search := TextInput{width: 220 height: 32 empty_text: "Search members..."}
                                }
                                mem_batch := RoundedView{visible: false width: Fill height: Fit margin: Inset{bottom: 12}
                                    padding: Inset{left: 16 right: 12 top: 8 bottom: 8} flow: Right spacing: 8 align: Align{y: 0.5}
                                    new_batch: true draw_bg.color: accent_12 draw_bg.border_radius: 4.0
                                    draw_bg.border_size: 1.0 draw_bg.border_color: accent_20
                                    mem_selected := Txt{width: Fill text: "" draw_text.color: accent_light}
                                    mem_batch_timeout := SmallBtn{t.text: "Timeout" t.draw_text.color: #xfbbf24}
                                    mem_batch_kick := SmallBtn{t.text: "Kick" t.draw_text.color: #xf87171}
                                    mem_batch_ban := SmallBtn{t.text: "Ban" t.draw_text.color: #xf87171}
                                }
                                mem_select_all := View{width: Fit height: Fit flow: Right spacing: 8 align: Align{y: 0.5}
                                    padding: Inset{left: 16 bottom: 8} cursor: MouseCursor.Hand
                                    mem_all_box := CheckBox16{}
                                    Txt{text: "Select all" draw_text.color: gray_500 draw_text.text_style.font_size: 9.0}
                                }
                                srv_members := mod.widgets.MemberAdminList{}
                            }

                            // Rails' emoji page: an upload row over the list.
                            spage_emoji := View{
                                visible: false
                                width: 768 height: Fit flow: Down
                                PageTitle{text: "Emoji" margin: Inset{bottom: 2}}
                                Hint{margin: Inset{bottom: 16} text: "Manage custom emojis for your server. Members can use them in messages with :name: syntax."}
                                em_upload := Card{flow: Right spacing: 12 align: Align{y: 0.5}
                                    em_preview := RoundedView{width: 56 height: 56 flow: Overlay align: Center cursor: MouseCursor.Hand new_batch: true
                                        draw_bg.color: gray_900 draw_bg.border_radius: 4.0 draw_bg.border_size: 1.0 draw_bg.border_color: gray_600
                                        plus := Txt{text: "+" draw_text.color: gray_500 draw_text.text_style.font_size: 16.0}
                                        img := Image{visible: false width: 40 height: 40 fit: ImageFit.Smallest}}
                                    View{width: Fill height: Fit flow: Down spacing: 4
                                        em_name := Field{empty_text: "emoji_name"}
                                        Hint{text: "PNG, GIF, WebP. Max 256KB. Lowercase letters, digits and _."}}
                                    em_submit := Button{text: "Upload"}
                                }
                                em_title := Txt{margin: Inset{top: 8 bottom: 10} text: "" draw_text.color: gray_300 draw_text.text_style: theme.font_bold{font_size: 9.0}}
                                em_list := mod.widgets.CustomList{}
                            }

                            spage_stickers := View{
                                visible: false
                                width: 768 height: Fit flow: Down
                                PageTitle{text: "Stickers" margin: Inset{bottom: 2}}
                                Hint{margin: Inset{bottom: 16} text: "Custom stickers that members can send in messages."}
                                st_upload := Card{flow: Right spacing: 12 align: Align{y: 0.0}
                                    st_preview := RoundedView{width: 96 height: 96 flow: Overlay align: Center cursor: MouseCursor.Hand new_batch: true
                                        draw_bg.color: gray_900 draw_bg.border_radius: 4.0 draw_bg.border_size: 1.0 draw_bg.border_color: gray_600
                                        plus := Txt{text: "+" draw_text.color: gray_500 draw_text.text_style.font_size: 18.0}
                                        img := Image{visible: false width: 80 height: 80 fit: ImageFit.Smallest}}
                                    View{width: Fill height: Fit flow: Down spacing: 6
                                        st_name := Field{empty_text: "Sticker name"}
                                        st_desc := Field{empty_text: "Description (optional)"}
                                        View{width: Fill height: Fit flow: Right align: Align{y: 0.5}
                                            Hint{width: Fill text: "PNG, GIF, WebP. Max 512KB."}
                                            st_submit := Button{text: "Upload"}}
                                    }
                                }
                                st_title := Txt{margin: Inset{top: 8 bottom: 10} text: "" draw_text.color: gray_300 draw_text.text_style: theme.font_bold{font_size: 9.0}}
                                st_list := mod.widgets.StickerList{}
                            }

                            spage_audit := View{
                                visible: false
                                width: 768 height: Fit flow: Down
                                PageTitle{text: "Audit Log" margin: Inset{bottom: 16}}
                                srv_audit := mod.widgets.AuditList{}
                            }

                            spage_bans := View{
                                visible: false
                                width: 768 height: Fit flow: Down
                                PageTitle{text: "Bans"}
                                srv_bans := mod.widgets.PeopleList{}
                            }
                        }
                        View{width: Fit height: Fit padding: 24 flow: Down align: Align{x: 0.5} spacing: 4
                            close_srv_settings := RoundedView{
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

                    // Rails' sticky bar while a role has unsaved changes.
                    role_save_bar := View{
                        visible: false
                        width: Fill height: Fill
                        align: Align{x: 0.5 y: 1.0}
                        RoundedView{width: 720 height: Fit margin: Inset{bottom: 20} padding: Inset{left: 20 right: 12 top: 10 bottom: 10}
                            flow: Right spacing: 12 align: Align{y: 0.5} new_batch: true
                            draw_bg.color: gray_950 draw_bg.border_radius: 4.0 draw_bg.border_size: 1.0 draw_bg.border_color: gray_700
                            role_note := Txt{width: Fill text: "Careful — you have unsaved changes!" draw_text.color: #xffffff}
                            role_reset := View{width: Fit height: Fit padding: 8 cursor: MouseCursor.Hand
                                Txt{text: "Reset" draw_text.color: gray_300}}
                            role_save := RoundedView{width: Fit height: Fit padding: Inset{left: 16 right: 16 top: 7 bottom: 7}
                                cursor: MouseCursor.Hand new_batch: true draw_bg.color: #x16a34a draw_bg.border_radius: 2.0
                                Txt{text: "Save Changes" draw_text.color: #xffffff draw_text.text_style: theme.font_bold{font_size: 9.5}}}
                        }
                    }

                    // Context menus, opened at the pointer (ctxmenu.rs).
                    // Rails' toasts: fixed top-4 right-4, rounded-lg, shadow,
                    // green for notices, red for errors; gone after 4s.
                    toast_layer := View{
                        width: Fill height: Fit
                        align: Align{x: 1.0}
                        padding: Inset{top: 16 right: 16}
                        flow: Down spacing: 8
                        t0 := Toast{} t1 := Toast{} t2 := Toast{}
                    }
                    // Rails' status emoji popover (320×380), emoji only.
                    status_layer := View{
                        visible: false
                        width: Fill height: Fill
                        status_picker := PickerPanel{visible: true width: 320 height: 380
                            tabs +: {visible: false}
                            clear_row := View{width: Fill height: Fit padding: Inset{left: 8 right: 8 bottom: 8}
                                status_clear := View{width: Fit height: Fit padding: 4 cursor: MouseCursor.Hand
                                    Txt{text: "Clear status emoji" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}}
                            }
                        }
                    }
                    card_layer := View{
                        visible: false
                        width: Fill height: Fill
                        card := ProfileCard{}
                    }
                    ctx_layer := View{
                        visible: false
                        width: Fill height: Fill
                        ctx_menu := RoundedView{
                            width: 200 height: Fit
                            flow: Down
                            padding: 6
                            new_batch: true
                            draw_bg.color: gray_900
                            draw_bg.border_radius: 8.0
                            draw_bg.border_size: 1.0
                            draw_bg.border_color: gray_700
                            s0 := CtxSlot{} s1 := CtxSlot{} s2 := CtxSlot{} s3 := CtxSlot{} s4 := CtxSlot{}
                            s5 := CtxSlot{} s6 := CtxSlot{} s7 := CtxSlot{} s8 := CtxSlot{} s9 := CtxSlot{}
                            s10 := CtxSlot{} s11 := CtxSlot{} s12 := CtxSlot{} s13 := CtxSlot{}
                        }
                    }
                    }

                    // Styled confirmation (Flutter's improvement over Rails'
                    // native confirm): black/60 backdrop, gray-800 radius 12,
                    // max 448 (spec: modals).
                    // Rails' picture editor: drag to reposition, slider to zoom.
                    crop_dialog := Modal{
                        content +: {
                            RoundedView{
                                width: 512 height: Fit
                                flow: Down spacing: 8
                                padding: 16
                                new_batch: true
                                draw_bg.color: gray_800
                                draw_bg.border_radius: 12.0
                                crop_title := Txt{text: "Edit Avatar" draw_text.color: #xffffff
                                    draw_text.text_style: theme.font_bold{font_size: 13.0}}
                                Hint{text: "Drag to reposition, use the slider to zoom."}
                                crop_view := View{
                                    width: 480 height: 300
                                    flow: Overlay
                                    clip_x: true clip_y: true
                                    cursor: MouseCursor.Move
                                    show_bg: true
                                    draw_bg.color: gray_950
                                    crop_img := Image{width: 100 height: 100 fit: ImageFit.Stretch}
                                    // Avatar: darkened outside the circle (Rails' r=110 of 300).
                                    crop_mask := View{
                                        width: Fill height: Fill
                                        show_bg: true
                                        draw_bg +: {
                                            circle: uniform(1.0)
                                            pixel: fn() {
                                                let p = self.pos * self.rect_size
                                                let c = self.rect_size * 0.5
                                                let r = min(self.rect_size.x, self.rect_size.y) * 0.4
                                                // 1: avatar circle; 2: icon square (rounded as the rail shows it).
                                                let rr = r * 0.33
                                                let q = abs(p - c) - vec2(r - rr, r - rr)
                                                let sq = length(max(q, vec2(0.0, 0.0))) + min(max(q.x, q.y), 0.0) - rr
                                                let d = mix(length(p - c) - r, sq, step(1.5, self.circle))
                                                let a = clamp(d + 0.5, 0.0, 1.0) * 0.55 * min(self.circle, 1.0)
                                                return vec4(0.0, 0.0, 0.0, a)
                                            }
                                        }
                                    }
                                }
                                View{width: Fill height: Fit flow: Right spacing: 8 align: Align{y: 0.5}
                                    crop_zoom := Slider{width: Fill text: "Zoom" min: 1.0 max: 3.0 default: 1.0}
                                }
                                View{width: Fill height: Fit flow: Right spacing: 12 align: Align{y: 0.5} margin: Inset{top: 4}
                                    crop_note := Hint{text: ""}
                                    crop_cancel := View{width: Fit height: Fit padding: 8 cursor: MouseCursor.Hand
                                        Txt{text: "Cancel" draw_text.color: gray_400}}
                                    crop_apply := Button{text: "Apply"}
                                }
                            }
                        }
                    }

                    confirm_dialog := Modal{
                        content +: {
                            RoundedView{
                                width: 448 height: Fit
                                flow: Down spacing: 8
                                padding: 24
                                new_batch: true
                                draw_bg.color: gray_800
                                draw_bg.border_radius: 12.0
                                confirm_title := Txt{text: "" draw_text.color: #xffffff
                                    draw_text.text_style: theme.font_bold{font_size: 13.0}}
                                confirm_body := Hint{text: ""}
                                confirm_reason := View{visible: false width: Fill height: Fit
                                    confirm_input := Field{empty_text: "Reason (optional)"}}
                                View{width: Fill height: Fit margin: Inset{top: 12} flow: Right spacing: 8 align: Align{y: 0.5}
                                    View{width: Fill height: 1}
                                    confirm_cancel := Button{text: "Cancel"}
                                    confirm_ok := Button{text: "Confirm" draw_text.color: #xf87171}
                                }
                            }
                        }
                    }

                    // Create or join (opened by the rail's +).
                    // Add a Server: Flutter's Browse/Create dialog. Browse is
                    // Rails' invite field over Flutter's discovery grid.
                    dialog := Modal{
                        content +: {
                            RoundedView{
                                width: 720 height: Fit
                                flow: Down
                                new_batch: true
                                draw_bg.color: gray_800
                                draw_bg.border_radius: 6.0
                                draw_bg.border_size: 1.0
                                draw_bg.border_color: gray_700_50
                                View{width: Fill height: Fit flow: Right align: Align{y: 0.5} padding: Inset{left: 20 right: 16 top: 16}
                                    Txt{width: Fill text: "Add a Server" draw_text.color: #xffffff
                                        draw_text.text_style: theme.font_bold{font_size: 14.0}}
                                    add_close := RoundedView{width: 32 height: 32 align: Center cursor: MouseCursor.Hand new_batch: true
                                        draw_bg.color: gray_700 draw_bg.border_radius: 16.0
                                        Ico{icon_walk: Walk{width: 14 height: 14} draw_icon.svg: crate_resource("self:resources/icons/close.svg")}}
                                }
                                View{width: Fill height: Fit flow: Right spacing: 8 padding: Inset{left: 20 top: 12 bottom: 12}
                                    add_tab_browse := TabPill{draw_bg.color: gray_600 label.text: "Browse"}
                                    add_tab_create := TabPill{label.text: "Create"}
                                }
                                SolidView{width: Fill height: 1 draw_bg.color: gray_700_50}
                                add_browse := View{width: Fill height: Fit flow: Down padding: 20
                                    Txt{text: "Have an invite?" draw_text.color: gray_200 draw_text.text_style: theme.font_bold{font_size: 10.5}}
                                    View{width: Fill height: Fit margin: Inset{top: 8} flow: Right spacing: 8 align: Align{y: 0.5}
                                        invite_link := TextInput{width: Fill height: 36 empty_text: "Paste invite link…"}
                                        join_server := Button{text: "Join"}
                                    }
                                    View{width: Fill height: Fit margin: Inset{top: 20 bottom: 12} flow: Right spacing: 6 align: Align{y: 0.5}
                                        Txt{width: Fill text: "DISCOVER SERVERS" draw_text.color: gray_400 draw_text.text_style: theme.font_bold{font_size: 8.5}}
                                        discover_refresh := View{width: Fit height: Fit padding: 4 cursor: MouseCursor.Hand
                                            Txt{text: "Refresh" draw_text.color: gray_400 draw_text.text_style.font_size: 9.0}}
                                    }
                                    discover_list := mod.widgets.DiscoverList{}
                                }
                                add_create := View{visible: false width: Fill height: Fit flow: Down padding: 20
                                    Txt{text: "Customize your server" draw_text.color: gray_200 draw_text.text_style: theme.font_bold{font_size: 12.0}}
                                    Hint{margin: Inset{top: 4} text: "Give it a name and a type. You can change everything later in Server Settings."}
                                    FieldLabel{text: "SERVER NAME"}
                                    new_server_name := TextInput{width: Fill height: 36 empty_text: "Server name"}
                                    FieldLabel{text: "SERVER TYPE"}
                                    new_server_type := DropDown{width: 240 labels: ["Community", "Friends & Family", "Gaming", "Work & Team", "18+"]}
                                    View{width: Fill height: Fit margin: Inset{top: 20} flow: Right
                                        View{width: Fill height: 1}
                                        create_server := Button{text: "Create Server"}
                                    }
                                }
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
    // A bare `module::Type` path trips the Script derive's field parser.
    #[rust]
    perms: ServerPerms,
    #[rust]
    roles: Vec<backend::RoleItem>,
    #[rust]
    channel_forms: Vec<backend::ChannelForm>,
    /// Channel dialog target: None = creating.
    #[rust]
    dialog_channel: Option<String>,
    /// Category dialog target: None = creating.
    #[rust]
    dialog_category: Option<String>,
    /// The action waiting on the confirm dialog.
    #[rust]
    pending: Option<Pending>,
    #[rust]
    categories: Vec<backend::RoleItem>,
    #[rust]
    server_name: String,
    /// Slots of the open context menu, and the menus it came from.
    #[rust]
    ctx: Vec<CtxSlotData>,
    #[rust]
    ctx_back: Vec<CtxMenuData>,
    /// The items of the open menu, so a submenu can come back to it.
    #[rust]
    ctx_items: Vec<ctxmenu::Item>,
    #[rust]
    members: Vec<backend::MemberRow>,
    #[rust]
    srv: ServerSettings,
    /// Roles as edited on the roles page (saved with Save Changes).
    #[rust]
    role_drafts: Vec<backend::RoleForm>,
    /// Role editor tab: Display, Permissions, Members.
    #[rust]
    role_tab: usize,
    #[rust]
    role_sel: usize,
    /// A message to jump to once its channel's timeline arrives.
    #[rust]
    pending_jump: Option<(String, String)>,
    /// A press landed in the search hints: the input's blur must not hide them.
    #[rust]
    press_in_suggest: bool,
    /// The account's saved theme; a preview reverts to it unless saved.
    #[rust]
    saved_theme: String,
    /// The settings page showing, restored after a restyle.
    #[rust]
    settings_page: usize,
    #[rust]
    srv_page: usize,
    /// Where the next profile card opens (its top left).
    #[rust]
    card_at: Option<DVec2>,
    #[rust]
    card: Card,
    /// In Home (DMs and friends).
    #[rust]
    home: bool,
    #[rust]
    home_data: Home,
    /// Friends page tab: Online, All, Pending, Blocked, Search.
    #[rust]
    friends_tab: usize,
    #[rust]
    found: Vec<backend::Person>,
    /// Which incoming request the bar shows.
    #[rust]
    bar_index: usize,
    /// The open DM's pubkey.
    #[rust]
    dm_with: Option<String>,
    #[rust]
    dm_name: String,
    /// Rails' spoiler toggle for the next message.
    #[rust]
    spoiler: bool,
    /// Where the pointer last went down, for menus opened from actions.
    #[rust]
    last_press: DVec2,
    #[rust]
    my_picture: Option<String>,
    /// The profile being edited: picture and banner URLs to save.
    #[rust]
    draft_picture: String,
    #[rust]
    draft_banner: String,
    /// The server icon and banner being edited on the overview page.
    #[rust]
    srv_icon: String,
    #[rust]
    srv_banner: String,
    /// An emoji or sticker picked but not uploaded: (sticker, bytes, mime).
    #[rust]
    custom_staged: Option<(bool, Vec<u8>, &'static str)>,
    /// Name and description of the emoji or sticker being uploaded.
    #[rust]
    custom_pending: Option<(String, String)>,
    #[rust]
    custom_file_name: Option<String>,
    /// The status emoji being edited (picked from the emoji dropdown).
    #[rust]
    status_emoji: String,
    /// The picture editor's state and the picked image's pixels.
    #[rust]
    crop: Option<(Crop, Vec<u32>, uploads::Purpose)>,
    #[rust]
    crop_drag: Option<DVec2>,
    #[rust]
    uploads: Uploads,
    /// Showing notifications: (text, kind, when it goes).
    #[rust]
    toasts: Vec<(String, Toast, std::time::Instant)>,
    #[rust]
    toast_timer: Timer,
    /// The picker: frequently used, collapsed sections, tab, the sets.
    #[rust]
    picker_frequent: Vec<Cell>,
    #[rust]
    picker_collapsed: HashSet<String>,
    #[rust]
    picker_tab: usize,
    #[rust]
    emoji_sets: Vec<ServerSet>,
    #[rust]
    gif_view: GifView,
    #[rust]
    gif_favorites: Vec<Gif>,
    #[rust]
    gif_collections: Vec<GifCollection>,
    #[rust]
    ctx_at: DVec2,
    /// Category picked when the channel page opened (create mode).
    #[rust]
    page_category: Option<String>,
}

/// An action that needs a yes first.
#[derive(Debug, Clone)]
pub enum Pending {
    Menu(ctxmenu::Action),
    Leave,
    DeleteRole(String),
    DeleteServer,
    RevokeInvite(String),
    JoinInvite(String),
    BatchKick(Vec<String>),
    RemoveEmoji(String),
    RemoveSticker(String),
    BatchBan(Vec<String>),
    /// (gid, owner hex) from discovery.
    JoinPublic(String, String),
}

/// One filled context-menu slot (separator above, action, label, danger).
#[derive(Debug, Clone)]
pub struct CtxSlotData {
    sep: bool,
    action: ctxmenu::Action,
    label: String,
    danger: bool,
}

#[derive(Debug, Clone)]
pub struct CtxMenuData {
    items: Vec<ctxmenu::Item>,
}

const CTX_SLOTS: [LiveId; ctxmenu::SLOTS] = [
    id!(s0), id!(s1), id!(s2), id!(s3), id!(s4), id!(s5), id!(s6),
    id!(s7), id!(s8), id!(s9), id!(s10), id!(s11), id!(s12), id!(s13),
];

/// Server settings pages: (nav, page, required permission check index).
const SRV_PAGES: [(&[LiveId], &[LiveId]); 8] = [
    (ids!(snav_overview), ids!(spage_overview)),
    (ids!(snav_members), ids!(spage_members)),
    (ids!(snav_roles), ids!(spage_roles)),
    (ids!(snav_invites), ids!(spage_invites)),
    (ids!(snav_bans), ids!(spage_bans)),
    (ids!(snav_emoji), ids!(spage_emoji)),
    (ids!(snav_stickers), ids!(spage_stickers)),
    (ids!(snav_audit), ids!(spage_audit)),
];

/// Whether the role drafts differ from what's saved, in what the editor
/// changes (not counts, or the order permissions happen to be listed in).
fn roles_differ(drafts: &[backend::RoleForm], saved: &[backend::RoleForm]) -> bool {
    let key = |r: &backend::RoleForm| {
        let mut perms = r.perms.clone();
        perms.sort();
        (r.id.clone(), r.name.trim().to_owned(), r.color.to_lowercase(), r.position, r.hoist, r.mentionable, perms)
    };
    let mut a: Vec<_> = drafts.iter().map(key).collect();
    let mut b: Vec<_> = saved.iter().map(key).collect();
    a.sort();
    b.sort();
    a != b
}

/// Flutter's server types: (wire value, label), in the dropdown's order.
const SERVER_TYPES: [(&str, &str); 5] = [
    ("community", "Community"),
    ("friends_family", "Friends & Family"),
    ("gaming", "Gaming"),
    ("work_team", "Work & Team"),
    ("adult", "18+"),
];

/// Rails' invite choices: seconds to expiry (0 = never) and max uses (0 = unlimited).
const INVITE_EXPIRY: [i64; 7] = [0, 30 * 60, 3600, 6 * 3600, 12 * 3600, 86400, 7 * 86400];
const INVITE_USES: [u32; 7] = [0, 1, 5, 10, 25, 50, 100];

const SETTINGS_PAGES: [(&[LiveId], &[LiveId]); 4] = [
    (ids!(nav_account), ids!(page_account)),
    (ids!(nav_profile), ids!(page_profile)),
    (ids!(nav_appearance), ids!(page_appearance)),
    (ids!(nav_relays), ids!(page_relays)),
];

const APPEARANCE_PAGE: usize = 2;

/// Picker tabs (Rails' order; GIFs wait for a Tenor key decision).
const PICKER_GIFS: usize = 0;
const PICKER_STICKERS: usize = 1;
const PICKER_EMOJI: usize = 2;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Toast {
    Success,
    Error,
    Info,
}

const TOAST_SLOTS: [&[LiveId]; 3] = [ids!(t0), ids!(t1), ids!(t2)];

const THEME_TILES: [(&[LiveId], &str); 7] = [
    (ids!(th_inferno), "inferno"),
    (ids!(th_frostfire), "frostfire"),
    (ids!(th_boron), "boron"),
    (ids!(th_brimstone), "brimstone"),
    (ids!(th_plasma), "plasma"),
    (ids!(th_pulsar), "pulsar"),
    (ids!(th_obsidian), "obsidian"),
];

/// Sets an input's text with the caret at the end, where typing continues.
fn set_text_end(cx: &mut Cx, input: &TextInputRef, text: &str) {
    input.set_text(cx, text);
    input.set_cursor(cx, makepad_widgets::makepad_draw::text::selection::Cursor { index: text.len(), prefer_next_row: false }, false);
}

fn set_rich_end(cx: &mut Cx, input: &rich_input::RichInputRef, text: &str) {
    input.set_text(cx, text);
    input.set_cursor(cx, makepad_widgets::makepad_draw::text::selection::Cursor { index: text.len(), prefer_next_row: false }, false);
}

impl App {
    fn send(&self, cmd: backend::Command) {
        if let Some(tx) = &self.backend {
            let _ = tx.send(cmd);
        }
    }

    fn focus_composer(&self, cx: &mut Cx) {
        if let Some(mut input) = self.ui.rich_input(cx, ids!(composer)).borrow_mut() {
            input.take_key_focus(cx);
        }
    }

    fn clear_bars(&mut self, cx: &mut Cx) {
        self.reply_to = None;
        if self.editing.take().is_some() {
            self.ui.rich_input(cx, ids!(composer)).set_text(cx, "");
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
                    MessageAction::Reply(i)
                    | MessageAction::Edit(i)
                    | MessageAction::Pin(i)
                    | MessageAction::Context(i, _)
                    | MessageAction::Author(i, _)
                    | MessageAction::Invite(i) => i,
                };
                l.row(i).cloned()
            });
        let Some(row) = row else { return };
        match action {
            MessageAction::Invite(_) => {
                let Some((link, backend::InviteCard::Ready(p))) = row.invite.clone() else { return };
                if p.joined {
                    self.set_home(cx, false);
                    self.send(backend::Command::SelectServer(p.gid.clone()));
                } else if p.age_restricted {
                    // Rails: joining an 18+ server is a confirmation.
                    let body = format!("{} is age-restricted (18+). By joining, you confirm you are 18 years of age or older.", p.name);
                    self.confirm(cx, Pending::JoinInvite(link), "Age-restricted server", &body, "I am 18 or older — Join", false);
                } else {
                    self.join_invite(cx, link);
                }
            }
            MessageAction::Author(_, at) => {
                // Rails: below the click, left-aligned.
                self.card_at = Some(at + dvec2(0.0, 8.0));
                self.send(backend::Command::Card(row.author_pk.clone()));
            }
            MessageAction::Reply(_) => {
                self.clear_bars(cx);
                self.reply_to = Some(row.id.clone());
                let preview: String = row.body.as_deref().unwrap_or("…").chars().take(80).collect();
                self.ui.label(cx, ids!(reply_bar.who)).set_text(cx, &row.author);
                self.ui.label(cx, ids!(reply_bar.label)).set_text(cx, &preview);
                self.ui.view(cx, ids!(reply_bar)).set_visible(cx, true);
                self.focus_composer(cx);
            }
            MessageAction::Edit(_) => {
                self.clear_bars(cx);
                self.editing = Some(row.id.clone());
                let composer = self.ui.rich_input(cx, ids!(composer));
                set_rich_end(cx, &composer, row.body.as_deref().unwrap_or(""));
                let preview: String = row.body.as_deref().unwrap_or("").chars().take(80).collect();
                self.ui.label(cx, ids!(edit_bar.label)).set_text(cx, &preview);
                self.ui.view(cx, ids!(edit_bar)).set_visible(cx, true);
                self.focus_composer(cx);
            }
            MessageAction::Pin(_) => self.send(backend::Command::Pin { id: row.id.clone(), pinned: !row.pinned }),
            MessageAction::Context(i, at) => {
                let items = self.message_menu(i, &row);
                self.open_menu(cx, items, at);
                return;
            }
        }
        self.ui.redraw(cx);
    }

    /// Switches the drawn theme. The DSL reads its tokens when it runs, so a
    /// style reload re-runs it and reapplies the tree in place.
    fn apply_theme(&mut self, cx: &mut Cx, name: &str) {
        if theme::set_current(name) {
            cx.request_style_reload();
        }
    }

    fn mark_theme_tiles(&mut self, cx: &mut Cx) {
        let current = theme::current().name;
        for (path, name) in THEME_TILES {
            let border = if name == current { lists::rgba(0xffffff, 0.6) } else { lists::rgba(0xffffff, 0.1) };
            let mut tile = self.ui.widget(cx, path);
            script_apply_eval!(cx, tile, {draw_bg +: {border_color: #(border)}});
        }
    }

    fn show_settings_page(&mut self, cx: &mut Cx, page: usize) {
        self.settings_page = page;
        self.mark_theme_tiles(cx);
        // Appearance shows the app through the overlay (Rails' theme-picker).
        let appearance = page == APPEARANCE_PAGE;
        self.ui.view(cx, ids!(settings_pages)).set_visible(cx, !appearance);
        let mut overlay = self.ui.widget(cx, ids!(settings));
        let bg = if appearance { lists::rgba(0, 0.0) } else { theme::tok("gray_900", 1.0) };
        script_apply_eval!(cx, overlay, {draw_bg +: {color: #(bg)}});
        for (i, (nav, view)) in SETTINGS_PAGES.iter().enumerate() {
            let active = i == page;
            self.ui.view(cx, view).set_visible(cx, active);
            let mut item = self.ui.widget(cx, nav);
            let (bg, fg) = if active {
                (theme::tok("gray_600", 1.0), lists::rgba(0xffffff, 1.0))
            } else {
                (lists::rgba(0x000000, 0.0), theme::tok("gray_400", 1.0))
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
        } else {
            // An unsaved preview goes back to the saved theme.
            let saved = if self.saved_theme.is_empty() { "inferno".to_owned() } else { self.saved_theme.clone() };
            self.apply_theme(cx, &saved);
        }
        self.ui.redraw(cx);
    }

    fn open_channel_page(&mut self, cx: &mut Cx, id: Option<String>, category: Option<String>) {
        let form = id
            .as_ref()
            .and_then(|id| self.channel_forms.iter().find(|f| f.id.as_ref() == Some(id)).cloned())
            .unwrap_or_default();
        self.dialog_channel = id.clone();
        self.page_category = category.clone();
        let creating = id.is_none();
        self.ui.label(cx, ids!(ch_title)).set_text(cx, if creating { "Create Channel" } else { "Edit Channel" });
        self.ui.label(cx, ids!(ch_subtitle)).set_text(cx, &format!("in {}", self.server_name));
        self.ui.button(cx, ids!(ch_save)).set_text(cx, if creating { "Create Channel" } else { "Save Changes" });
        self.ui.view(cx, ids!(ch_danger)).set_visible(cx, !creating);
        self.ui.view(cx, ids!(create_only)).set_visible(cx, creating);
        // Encryption can't be changed after creation (the key is fixed).
        self.ui.check_box(cx, ids!(ch_encrypted)).set_visible(cx, creating);
        self.ui.text_input(cx, ids!(ch_name)).set_text(cx, &form.name);
        self.ui.text_input(cx, ids!(ch_topic)).set_text(cx, &form.topic);
        self.ui.drop_down(cx, ids!(ch_type)).set_selected_item(cx, 0);
        let mut labels = vec!["None".to_owned()];
        labels.extend(self.categories.iter().map(|c| c.name.clone()));
        let dd = self.ui.drop_down(cx, ids!(ch_category));
        dd.set_labels(cx, labels);
        let pick = category.and_then(|c| self.categories.iter().position(|x| x.id == c)).map_or(0, |i| i + 1);
        dd.set_selected_item(cx, pick);
        for (path, v) in [(ids!(ch_encrypted), form.encrypted), (ids!(ch_post_only), form.post_only), (ids!(ch_nsfw), form.nsfw)] {
            self.ui.check_box(cx, path).set_active(cx, v, Animate::No);
        }
        // @everyone is offered as "Everyone", since it means all members.
        let roles: Vec<(String, String, bool)> = self
            .roles
            .iter()
            .map(|r| {
                let label = if r.name == "@everyone" { "Everyone".to_owned() } else { r.name.clone() };
                (r.id.clone(), label, form.allowed_roles.contains(&r.id))
            })
            .collect();
        if let Some(mut picker) = self.ui.widget(cx, ids!(ch_roles)).borrow_mut::<lists::RolePicker>() {
            picker.roles = roles;
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(ch_roles.list)));
        self.ui.view(cx, ids!(ch_roles_box)).set_visible(cx, form.encrypted);
        self.ui.view(cx, ids!(channel_page)).set_visible(cx, true);
        self.ui.redraw(cx);
    }

    fn open_category_page(&mut self, cx: &mut Cx, id: Option<String>) {
        let name = id
            .as_ref()
            .and_then(|id| self.categories.iter().find(|c| &c.id == id))
            .map(|c| c.name.clone())
            .unwrap_or_default();
        self.dialog_category = id.clone();
        let creating = id.is_none();
        self.ui.label(cx, ids!(cat_title)).set_text(cx, if creating { "Create Category" } else { "Edit Category" });
        self.ui.button(cx, ids!(cat_save)).set_text(cx, if creating { "Create Category" } else { "Edit Category" });
        self.ui.text_input(cx, ids!(cat_name)).set_text(cx, &name);
        self.ui.view(cx, ids!(category_page)).set_visible(cx, true);
        self.ui.redraw(cx);
    }

    /// Opens or closes the server dropdown, showing only what we may do.
    fn set_server_menu(&mut self, cx: &mut Cx, open: bool) {
        if open {
            let p = self.perms.clone();
            self.ui.view(cx, ids!(menu_create_channel)).set_visible(cx, p.manage_channels);
            self.ui.view(cx, ids!(menu_create_category)).set_visible(cx, p.manage_channels);
            self.ui.view(cx, ids!(menu_server_settings)).set_visible(cx, p.manage_server);
            self.ui.view(cx, ids!(menu_leave)).set_visible(cx, !p.owner);
            self.ui.view(cx, ids!(menu_invite)).set_visible(cx, p.create_invite);
            self.ui.view(cx, ids!(menu_divider)).set_visible(cx, !p.owner || p.create_invite);
        }
        self.ui.view(cx, ids!(server_menu)).set_visible(cx, open);
        self.ui.redraw(cx);
    }

    fn close_pages(&mut self, cx: &mut Cx) {
        self.ui.view(cx, ids!(channel_page)).set_visible(cx, false);
        self.ui.view(cx, ids!(category_page)).set_visible(cx, false);
        self.ui.redraw(cx);
    }

    // ─── Context menus ───────────────────────────────────────────────────

    fn open_menu(&mut self, cx: &mut Cx, items: Vec<ctxmenu::Item>, at: DVec2) {
        let slots = ctxmenu::layout(&items);
        self.ctx_items = items;
        if slots.is_empty() {
            return;
        }
        self.ctx = slots
            .iter()
            .map(|(sep, action, label, danger)| CtxSlotData { sep: *sep, action: action.clone(), label: label.clone(), danger: *danger })
            .collect();
        for (i, slot_id) in CTX_SLOTS.iter().enumerate() {
            let slot = self.ui.view(cx, &[id!(ctx_menu), *slot_id]);
            match self.ctx.get(i) {
                Some(d) => {
                    slot.set_visible(cx, true);
                    self.ui.view(cx, &[id!(ctx_menu), *slot_id, id!(sep)]).set_visible(cx, d.sep);
                    let mut label = self.ui.widget(cx, &[id!(ctx_menu), *slot_id, id!(item), id!(label)]);
                    let color = if d.danger { lists::rgba(0xf87171, 1.0) } else { theme::tok("gray_300", 1.0) };
                    script_apply_eval!(cx, label, {draw_text +: {color: #(color)}});
                    label.set_text(cx, &d.label);
                }
                None => slot.set_visible(cx, false),
            }
        }
        let win = self.ui.view(cx, ids!(ctx_layer)).area().rect(cx).size;
        let win = if win.x > 0.0 { win } else { dvec2(1400.0, 860.0) };
        let (x, y) = ctxmenu::place((at.x, at.y), (ctxmenu::WIDTH, ctxmenu::height(&slots)), (win.x, win.y));
        let mut menu = self.ui.widget(cx, ids!(ctx_menu));
        script_apply_eval!(cx, menu, {margin: mod.prelude.widgets.Inset{left: #(x) top: #(y)}});
        self.ctx_at = at;
        self.ui.view(cx, ids!(ctx_layer)).set_visible(cx, true);
        self.ui.redraw(cx);
    }

    /// Replaces the open menu with a submenu, remembering where it was.
    fn open_submenu(&mut self, cx: &mut Cx, items: Vec<ctxmenu::Item>) {
        self.ctx_back.push(CtxMenuData { items: self.ctx_items.clone() });
        let at = self.ctx_at;
        self.open_menu(cx, items, at);
    }

    fn close_menu(&mut self, cx: &mut Cx) {
        self.ctx.clear();
        self.ctx_back.clear();
        self.ctx_items.clear();
        self.ui.view(cx, ids!(ctx_layer)).set_visible(cx, false);
        self.ui.redraw(cx);
    }

    fn sidebar_menu(&self, row: Option<&backend::SidebarRow>) -> Vec<ctxmenu::Item> {
        use ctxmenu::{Action as A, Item};
        let manage = self.perms.manage_channels;
        match row {
            // Rails: empty sidebar space, manage_channels only.
            None => {
                if !manage {
                    return vec![];
                }
                vec![Item::new("Create Channel", A::CreateChannel { category: None }), Item::new("Create Category", A::CreateCategory)]
            }
            Some(backend::SidebarRow::Channel { id, .. }) => {
                let mut v = vec![Item::new("Mark as Read", A::MarkRead(id.clone()))];
                if manage {
                    v.push(Item::Separator);
                    v.push(Item::new("Edit Channel", A::EditChannel(id.clone())));
                    v.push(Item::danger("Delete Channel", A::DeleteChannel(id.clone())));
                }
                v.push(Item::Separator);
                v.push(Item::new("Copy Channel ID", A::Copy(id.clone())));
                v
            }
            Some(backend::SidebarRow::Category { id, .. }) => {
                let mut v = vec![];
                if manage {
                    v.push(Item::new("Create Channel", A::CreateChannel { category: Some(id.clone()) }));
                    v.push(Item::Separator);
                    v.push(Item::new("Edit Category", A::EditCategory(id.clone())));
                    v.push(Item::danger("Delete Category", A::DeleteCategory(id.clone())));
                    v.push(Item::Separator);
                }
                v.push(Item::new("Copy Category ID", A::Copy(id.clone())));
                v
            }
        }
    }

    fn confirm(&mut self, cx: &mut Cx, pending: Pending, title: &str, body: &str, ok: &str, reason: bool) {
        self.pending = Some(pending);
        self.ui.label(cx, ids!(confirm_title)).set_text(cx, title);
        self.ui.label(cx, ids!(confirm_body)).set_text(cx, body);
        self.ui.button(cx, ids!(confirm_ok)).set_text(cx, ok);
        self.ui.text_input(cx, ids!(confirm_input)).set_text(cx, "");
        self.ui.view(cx, ids!(confirm_reason)).set_visible(cx, reason);
        self.ui.modal(cx, ids!(confirm_dialog)).open(cx);
    }

    /// Runs a picked menu action (destructive ones ask first).
    fn run_menu_action(&mut self, cx: &mut Cx, action: ctxmenu::Action) {
        use ctxmenu::Action as A;
        match action {
            A::CreateChannel { category } => self.open_channel_page(cx, None, category),
            A::CreateCategory => self.open_category_page(cx, None),
            A::MarkRead(id) => self.send(backend::Command::MarkRead(id)),
            A::EditChannel(id) => self.open_channel_page(cx, Some(id), None),
            A::EditCategory(id) => self.open_category_page(cx, Some(id)),
            A::Copy(text) => cx.copy_to_clipboard(&text),
            A::DeleteChannel(_) => self.confirm(
                cx,
                Pending::Menu(action),
                "Delete Channel",
                "Are you sure? All messages in this channel will be permanently deleted.",
                "Delete Channel",
                false,
            ),
            A::DeleteCategory(_) => self.confirm(
                cx,
                Pending::Menu(action),
                "Delete Category",
                "Are you sure? Channels in this category will become uncategorized.",
                "Delete Category",
                false,
            ),
            A::Message(pk) => self.open_dm(cx, pk),
            A::GifFavorite(gif) => self.send(backend::Command::ToggleGifFavorite(gif)),
            A::GifCollection { id, gif } => self.send(backend::Command::ToggleGifInCollection { id, gif }),
            A::DeleteGifCollection(id) => self.send(backend::Command::DeleteGifCollection(id)),
            A::AddFriend(pk) => self.send(backend::Command::AddFriend(pk)),
            A::AcceptFriend(pk) => self.send(backend::Command::AnswerFriend { pubkey: pk, accept: true }),
            A::DeclineFriend(pk) => self.send(backend::Command::AnswerFriend { pubkey: pk, accept: false }),
            A::MarkDmRead(pk) => self.send(backend::Command::MarkDmRead(pk)),
            A::CloseDm(pk) => {
                if self.dm_with.as_deref() == Some(pk.as_str()) {
                    self.show_friends(cx, self.friends_tab);
                }
                self.send(backend::Command::CloseDm(pk));
            }
            A::RemoveFriend(_) => self.confirm(cx, Pending::Menu(action), "Remove Friend", "Remove friend?", "Remove", false),
            A::Block(ref pk) => {
                let name = self
                    .home_data
                    .conversations
                    .iter()
                    .find(|c| c.person.pubkey == *pk)
                    .map(|c| c.person.name.clone())
                    .unwrap_or_else(|| "this person".into());
                let body = format!("Block {name}? They won't be able to message you, and will be removed from your friends.");
                self.confirm(cx, Pending::Menu(action.clone()), "Block User", &body, "Block", false)
            }
            other => self.run_message_or_member_action(cx, other),
        }
    }

    fn message_row(&self, cx: &mut Cx, i: usize) -> Option<backend::MessageRow> {
        self.ui.widget(cx, ids!(messages)).borrow::<message_list::MessageList>().and_then(|l| l.row(i).cloned())
    }

    /// Rails' message menu, for what exists so far (reactions, images and
    /// links join with those features).
    fn message_menu(&self, i: usize, row: &backend::MessageRow) -> Vec<ctxmenu::Item> {
        use ctxmenu::{Action as A, Item};
        let link = inferno_core::nostr::prelude::EventId::from_hex(&row.id)
            .ok()
            .and_then(|id| {
                use inferno_core::nostr::nips::nip19::ToBech32;
                inferno_core::nostr::nips::nip19::Nip19Event::new(id).to_bech32().ok()
            })
            .map(|n| format!("nostr:{n}"))
            .unwrap_or_default();
        let mut v = vec![
            Item::new("Reply", A::Reply(i)),
            Item::Separator,
            Item::new("Copy Text", A::Copy(row.body.clone().unwrap_or_default())),
            Item::new("Copy Message Link", A::Copy(link)),
        ];
        if self.perms.manage_messages {
            v.push(Item::new(if row.pinned { "Unpin Message" } else { "Pin Message" }, A::Pin(i)));
        }
        if row.own {
            v.push(Item::Separator);
            v.push(Item::new("Edit Message", A::Edit(i)));
            v.push(Item::danger("Delete Message", A::DeleteMessage(i)));
        } else if self.perms.manage_messages {
            v.push(Item::Separator);
            v.push(Item::danger("Delete Message", A::DeleteMessage(i)));
        }
        v
    }

    fn member(&self, pubkey: &str) -> Option<(String, Vec<String>, bool, bool)> {
        self.members.iter().find_map(|m| match m {
            backend::MemberRow::Member { name, pubkey: pk, roles, owner, me, .. } if pk == pubkey => {
                Some((name.clone(), roles.clone(), *owner, *me))
            }
            _ => None,
        })
    }

    /// Rails' member menu, with Flutter's timeout presets and ban reason.
    /// Rails' DM sidebar menu.
    fn dm_menu(&self, r: &backend::DmRow) -> Vec<ctxmenu::Item> {
        use ctxmenu::{Action as A, Item};
        let pk = r.person.pubkey.clone();
        let mut v = Vec::new();
        v.extend(self.friend_items(&pk, r.friend));
        v.push(Item::danger("Block User", A::Block(pk.clone())));
        v.push(Item::Separator);
        v.push(Item::new("Mark as Read", A::MarkDmRead(pk.clone())));
        v.push(Item::new("Close Conversation", A::CloseDm(pk)));
        v
    }

    fn friend_items(&self, pk: &str, friend: Friend) -> Vec<ctxmenu::Item> {
        use ctxmenu::{Action as A, Item};
        match friend {
            Friend::Accepted => vec![Item::danger("Remove Friend", A::RemoveFriend(pk.into()))],
            Friend::Incoming => vec![
                Item::new("Accept Friend Request", A::AcceptFriend(pk.into())),
                Item::new("Decline Friend Request", A::DeclineFriend(pk.into())),
            ],
            Friend::Outgoing => vec![Item::new("Cancel Friend Request", A::RemoveFriend(pk.into()))],
            Friend::None => vec![Item::new("Add Friend", A::AddFriend(pk.into()))],
        }
    }

    fn member_menu(&self, pubkey: &str) -> Vec<ctxmenu::Item> {
        use ctxmenu::{Action as A, Item};
        let Some((name, _, owner, me)) = self.member(pubkey) else { return vec![] };
        let p = &self.perms;
        let mut v = vec![Item::new("Mention", A::Mention(name.clone()))];
        if !me {
            // Rails: Message, then the friend action for where we stand.
            let friend = self
                .home_data
                .friends
                .iter()
                .any(|f| f.pubkey == pubkey)
                .then_some(Friend::Accepted)
                .or_else(|| self.home_data.incoming.iter().any(|f| f.pubkey == pubkey).then_some(Friend::Incoming))
                .or_else(|| self.home_data.outgoing.iter().any(|f| f.pubkey == pubkey).then_some(Friend::Outgoing))
                .unwrap_or_default();
            v.push(Item::Separator);
            v.push(Item::new("Message", A::Message(pubkey.into())));
            v.extend(self.friend_items(pubkey, friend));
        }
        if p.manage_roles && !owner {
            v.push(Item::Separator);
            v.push(Item::new("Roles  ›", A::RolesFor(pubkey.into())));
        }
        if !me && !owner && (p.kick_members || p.ban_members) {
            v.push(Item::Separator);
            if p.kick_members {
                v.push(Item::new("Timeout  ›", A::TimeoutFor(pubkey.into())));
                v.push(Item::danger(format!("Kick {name}"), A::Kick(pubkey.into())));
            }
            if p.ban_members {
                v.push(Item::danger(format!("Ban {name}"), A::Ban(pubkey.into())));
            }
        }
        v.push(Item::Separator);
        let npub = inferno_core::nostr::prelude::PublicKey::from_hex(pubkey)
            .ok()
            .and_then(|pk| {
                use inferno_core::nostr::nips::nip19::ToBech32;
                pk.to_bech32().ok()
            })
            .unwrap_or_else(|| pubkey.to_owned());
        v.push(Item::new("Copy User ID", A::Copy(npub)));
        v
    }

    /// A member's roles to toggle: only those below our own highest
    /// (Flutter's hierarchy rule).
    fn roles_menu(&self, pubkey: &str, back: bool) -> Vec<ctxmenu::Item> {
        use ctxmenu::{Action as A, Item};
        let held = self.member(pubkey).map(|m| m.1).unwrap_or_default();
        let mut v = if back { vec![Item::new("‹  Back", A::Back), Item::Separator] } else { vec![] };
        let rank = self.srv.my_rank;
        let assignable: std::collections::HashSet<&str> =
            self.srv.roles.iter().filter(|r| !r.everyone && r.position < rank).map(|r| r.id.as_str()).collect();
        for r in self.roles.iter().filter(|r| assignable.contains(r.id.as_str())) {
            let mark = if held.contains(&r.id) { "✓" } else { "  " };
            v.push(Item::new(format!("{mark}  {}", r.name), A::ToggleRole { member: pubkey.into(), role: r.id.clone() }));
        }
        v
    }

    fn timeout_menu(&self, pubkey: &str, back: bool) -> Vec<ctxmenu::Item> {
        use ctxmenu::{Action as A, Item};
        let mut v = if back { vec![Item::new("‹  Back", A::Back), Item::Separator] } else { vec![] };
        for (label, secs) in [
            ("60 seconds", 60),
            ("5 minutes", 300),
            ("10 minutes", 600),
            ("1 hour", 3_600),
            ("1 day", 86_400),
            ("1 week", 604_800),
        ] {
            v.push(Item::new(label, A::Timeout { member: pubkey.into(), secs }));
        }
        v.push(Item::Separator);
        v.push(Item::new("Remove Timeout", A::Timeout { member: pubkey.into(), secs: 0 }));
        v
    }

    fn batch_timeout_menu(&self) -> Vec<ctxmenu::Item> {
        use ctxmenu::{Action as A, Item};
        [("60 seconds", 60), ("5 minutes", 300), ("10 minutes", 600), ("1 hour", 3_600), ("1 day", 86_400), ("1 week", 604_800)]
            .into_iter()
            .map(|(label, secs)| Item::new(label, A::BatchTimeout(secs)))
            .collect()
    }

    /// Message and member menu actions.
    fn run_message_or_member_action(&mut self, cx: &mut Cx, action: ctxmenu::Action) {
        use ctxmenu::Action as A;
        use message_list::MessageAction as M;
        match action {
            A::Reply(i) => self.message_action(cx, M::Reply(i)),
            A::Edit(i) => self.message_action(cx, M::Edit(i)),
            A::Pin(i) => self.message_action(cx, M::Pin(i)),
            A::DeleteMessage(_) => self.confirm(
                cx,
                Pending::Menu(action),
                "Delete Message",
                "Are you sure you want to delete this message? This can't be undone.",
                "Delete",
                false,
            ),
            A::Mention(name) => {
                let composer = self.ui.rich_input(cx, ids!(composer));
                let mut text = composer.text();
                if !text.is_empty() && !text.ends_with(' ') {
                    text.push(' ');
                }
                text.push_str(&format!("@{name} "));
                set_rich_end(cx, &composer, &text);
                self.focus_composer(cx);
            }
            A::RolesFor(pk) => {
                let items = self.roles_menu(&pk, true);
                self.open_submenu(cx, items);
            }
            A::TimeoutFor(pk) => {
                let items = self.timeout_menu(&pk, true);
                self.open_submenu(cx, items);
            }
            A::ToggleRole { member, role } => {
                let mut roles = self.member(&member).map(|m| m.1).unwrap_or_default();
                if let Some(i) = roles.iter().position(|r| *r == role) {
                    roles.remove(i);
                } else {
                    roles.push(role);
                }
                self.send(backend::Command::SetMemberRoles { pubkey: member, roles });
            }
            A::Timeout { member, secs } => self.send(backend::Command::Timeout { pubkey: member, secs }),
            A::BatchTimeout(secs) => {
                for pk in self.selected_members(cx) {
                    self.send(backend::Command::Timeout { pubkey: pk, secs });
                }
                self.clear_member_selection(cx);
            }
            A::Kick(ref pk) => {
                let name = self.member(pk).map(|m| m.0).unwrap_or_default();
                let body = format!("Kick {name} from {}?", self.server_name);
                self.confirm(cx, Pending::Menu(action), "Kick Member", &body, "Kick", false);
            }
            A::Ban(ref pk) => {
                let name = self.member(pk).map(|m| m.0).unwrap_or_default();
                let body = format!("Ban {name} from {}?", self.server_name);
                self.confirm(cx, Pending::Menu(action), "Ban Member", &body, "Ban", true);
            }
            A::Back => {
                if let Some(prev) = self.ctx_back.pop() {
                    let at = self.ctx_at;
                    let back = std::mem::take(&mut self.ctx_back);
                    self.open_menu(cx, prev.items, at);
                    self.ctx_back = back;
                }
            }
            _ => {}
        }
    }

    /// The confirmed side of a pending action.
    fn run_confirmed(&mut self, cx: &mut Cx, pending: Pending) {
        use ctxmenu::Action as A;
        let reason = self.ui.text_input(cx, ids!(confirm_input)).text();
        match pending {
            Pending::Leave => self.send(backend::Command::LeaveServer),
            Pending::Menu(A::DeleteChannel(id)) => {
                self.send(backend::Command::DeleteChannel(id));
                self.close_pages(cx);
            }
            Pending::Menu(A::DeleteCategory(id)) => self.send(backend::Command::DeleteCategory(id)),
            Pending::Menu(A::DeleteMessage(i)) => {
                if let Some(row) = self.message_row(cx, i) {
                    self.send(backend::Command::DeleteMessage(row.id));
                }
            }
            Pending::Menu(A::Kick(pk)) => self.send(backend::Command::Kick(pk)),
            Pending::Menu(A::RemoveFriend(pk)) => self.send(backend::Command::RemoveFriend(pk)),
            Pending::Menu(A::Block(pk)) => {
                if self.dm_with.as_deref() == Some(pk.as_str()) {
                    self.show_friends(cx, self.friends_tab);
                }
                self.send(backend::Command::Block(pk));
            }
            Pending::Menu(A::Ban(pk)) => self.send(backend::Command::Ban { pubkey: pk, reason: reason.trim().to_owned() }),
            Pending::DeleteRole(id) => {
                self.role_drafts.retain(|r| r.id != id);
                self.role_sel = 0;
                self.send(backend::Command::SaveRoles(self.role_drafts.clone()));
                self.show_role(cx);
            }
            Pending::DeleteServer => {
                self.ui.view(cx, ids!(srv_settings)).set_visible(cx, false);
        self.ui.view(cx, ids!(role_save_bar)).set_visible(cx, false);
                self.send(backend::Command::DeleteServer);
                self.ui.redraw(cx);
            }
            Pending::RevokeInvite(code) => self.send(backend::Command::RevokeInvite(code)),
            Pending::JoinInvite(link) => self.join_invite(cx, link),
            Pending::RemoveEmoji(name) => self.send(backend::Command::RemoveEmoji(name)),
            Pending::RemoveSticker(name) => self.send(backend::Command::RemoveSticker(name)),
            Pending::BatchKick(pks) => {
                for pk in pks {
                    self.send(backend::Command::Kick(pk));
                }
                self.clear_member_selection(cx);
            }
            Pending::BatchBan(pks) => {
                for pk in pks {
                    self.send(backend::Command::Ban { pubkey: pk, reason: reason.trim().to_owned() });
                }
                self.clear_member_selection(cx);
            }
            Pending::JoinPublic(gid, owner) => {
                self.send(backend::Command::JoinPublic { gid, owner });
                self.toast(cx, "Joining…", Toast::Info);
            }
            Pending::Menu(_) => {}
        }
    }

    // ─── Server settings ─────────────────────────────────────────────────

    /// Which server settings pages we may open (Rails' gates).
    fn srv_page_allowed(&self) -> [bool; 8] {
        let p = &self.perms;
        [
            p.manage_server,
            p.manage_server || p.manage_roles,
            p.manage_server || p.manage_roles,
            p.create_invite || p.manage_invites,
            p.manage_server || p.ban_members,
            p.create_emojis || p.manage_emojis || p.manage_server,
            p.create_stickers || p.manage_emojis || p.manage_server,
            p.manage_server,
        ]
    }

    fn open_srv_settings(&mut self, cx: &mut Cx) {
        let allowed = self.srv_page_allowed();
        for (i, (nav, _)) in SRV_PAGES.iter().enumerate() {
            self.ui.view(cx, nav).set_visible(cx, allowed[i]);
        }
        self.ui.view(cx, ids!(snav_delete)).set_visible(cx, self.perms.owner);
        self.ui.widget(cx, ids!(people_hdr)).set_visible(cx, allowed[1] || allowed[2] || allowed[3]);
        self.ui.widget(cx, ids!(expression_hdr)).set_visible(cx, allowed[5] || allowed[6]);
        self.ui.widget(cx, ids!(moderation_hdr)).set_visible(cx, allowed[4] || allowed[7]);
        self.ui.label(cx, ids!(srv_nav_title)).set_text(cx, &self.server_name.to_uppercase());
        self.fill_srv_pages(cx);
        if let Some(first) = allowed.iter().position(|a| *a) {
            self.show_srv_page(cx, first);
        }
        self.ui.view(cx, ids!(srv_settings)).set_visible(cx, true);
        self.ui.redraw(cx);
    }

    fn show_srv_page(&mut self, cx: &mut Cx, page: usize) {
        self.srv_page = page;
        let dirty = roles_differ(&self.role_drafts, &self.srv.roles);
        self.ui.view(cx, ids!(role_save_bar)).set_visible(cx, dirty && page == 2);
        for (i, (nav, view)) in SRV_PAGES.iter().enumerate() {
            let active = i == page;
            self.ui.view(cx, view).set_visible(cx, active);
            let mut item = self.ui.widget(cx, nav);
            let (bg, fg) = if active {
                (theme::tok("gray_600", 1.0), lists::rgba(0xffffff, 1.0))
            } else {
                (lists::rgba(0x000000, 0.0), theme::tok("gray_400", 1.0))
            };
            script_apply_eval!(cx, item, {draw_bg +: {color: #(bg)}});
            let mut label = self.ui.widget(cx, &[nav[0], id!(label)]);
            script_apply_eval!(cx, label, {draw_text +: {color: #(fg)}});
        }
        self.ui.redraw(cx);
    }

    /// Copies the latest settings snapshot into the pages.
    fn fill_srv_pages(&mut self, cx: &mut Cx) {
        let o = self.srv.clone();
        self.ui.text_input(cx, ids!(so_name)).set_text(cx, &o.name);
        self.ui.text_input(cx, ids!(so_about)).set_text(cx, &o.about);
        self.ui.text_input(cx, ids!(so_welcome)).set_text(cx, &o.welcome_message);
        for (path, v) in [(ids!(so_discoverable), o.discoverable), (ids!(so_age), o.age_restricted), (ids!(so_welcome_on), o.welcome_enabled)] {
            self.ui.check_box(cx, path).set_active(cx, v, Animate::No);
        }
        let ty = SERVER_TYPES.iter().position(|(v, _)| *v == o.server_type).unwrap_or(0);
        self.ui.drop_down(cx, ids!(so_type)).set_selected_item(cx, ty);
        let mut labels = vec!["Default (first text channel)".to_owned()];
        labels.extend(o.text_channels.iter().map(|c| format!("#{}", c.name)));
        let dd = self.ui.drop_down(cx, ids!(so_welcome_ch));
        dd.set_labels(cx, labels);
        let ch = o.welcome_channel.as_ref().and_then(|w| o.text_channels.iter().position(|c| &c.id == w)).map_or(0, |i| i + 1);
        dd.set_selected_item(cx, ch);
        self.srv_icon = o.picture.clone();
        self.srv_banner = o.banner.clone();
        self.paint_server_preview(cx);
        self.fill_invites(cx);
        self.fill_custom(cx);
        if let Some(mut l) = self.ui.widget(cx, ids!(srv_audit)).borrow_mut::<lists::AuditList>() {
            l.rows = o.audit.clone();
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(srv_audit.list)));
        self.role_drafts = o.roles.clone();
        self.role_sel = self.role_sel.min(self.role_drafts.len().saturating_sub(1));
        self.show_role(cx);
        self.fill_people(cx);
    }

    /// Add a Server's tabs (Flutter): Browse or Create.
    fn add_server_tab(&mut self, cx: &mut Cx, create: bool) {
        self.ui.view(cx, ids!(add_browse)).set_visible(cx, !create);
        self.ui.view(cx, ids!(add_create)).set_visible(cx, create);
        for (path, on) in [(ids!(add_tab_browse), !create), (ids!(add_tab_create), create)] {
            let mut pill = self.ui.widget(cx, path);
            let bg = if on { theme::tok("gray_600", 1.0) } else { lists::rgba(0, 0.0) };
            script_apply_eval!(cx, pill, {draw_bg +: {color: #(bg)}});
        }
        self.ui.redraw(cx);
    }

    /// Asks the relays for public servers; the grid shows "Searching…".
    fn discover(&mut self, cx: &mut Cx) {
        if let Some(mut l) = self.ui.widget(cx, ids!(discover_list)).borrow_mut::<lists::DiscoverList>() {
            l.searching = true;
            l.servers.clear();
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(discover_list.list)));
        self.send(backend::Command::Discover);
    }

    /// Joins from an invite card and goes there.
    fn join_invite(&mut self, cx: &mut Cx, link: String) {
        self.set_home(cx, false);
        self.send(backend::Command::Join(link));
        self.toast(cx, "Joining…", Toast::Info);
    }

    /// Invite People: Rails hands out the server's open invite rather than
    /// making a new one each time; a new one never expires.
    fn invite_people(&mut self, cx: &mut Cx) {
        let now = chrono::Utc::now().timestamp();
        let open = self.srv.invites.iter().find(|i| {
            i.can_revoke && (i.expires_at == 0 || i.expires_at > now + 3600) && (i.max_uses == 0 || i.uses < i.max_uses)
        });
        match open {
            Some(i) => {
                cx.copy_to_clipboard(&i.link);
                self.toast(cx, "Invite link copied.", Toast::Success);
            }
            None => self.send(backend::Command::CreateInvite { max_uses: 0, expires_in: 0 }),
        }
    }

    /// The overview's preview card, from what the form says now.
    fn paint_server_preview(&mut self, cx: &mut Cx) {
        let name = self.ui.text_input(cx, ids!(so_name)).text();
        let about = self.ui.text_input(cx, ids!(so_about)).text();
        let initial = name.trim().chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_else(|| "?".into());
        self.ui.label(cx, ids!(sp_name)).set_text(cx, &name);
        self.ui.label(cx, ids!(sp_about)).set_text(cx, &about);
        self.ui.widget(cx, ids!(sp_about)).set_visible(cx, !about.trim().is_empty());
        self.ui.label(cx, ids!(sp_icon.initial)).set_text(cx, &initial);
        let n = self.srv.member_count;
        self.ui.label(cx, ids!(sp_members)).set_text(cx, &format!("{n} Member{}", if n == 1 { "" } else { "s" }));
        let ty = self.ui.drop_down(cx, ids!(so_type)).selected_item().min(SERVER_TYPES.len() - 1);
        self.ui.label(cx, ids!(sp_type.label)).set_text(cx, SERVER_TYPES[ty].1);
        let age = self.ui.check_box(cx, ids!(so_age)).active(cx);
        self.ui.view(cx, ids!(sp_age)).set_visible(cx, age && SERVER_TYPES[ty].0 != "adult");
        let (icon, banner) = (self.srv_icon.clone(), self.srv_banner.clone());
        images::show(cx, &self.ui.image(cx, ids!(sp_icon.pic)), Some(icon.as_str()).filter(|u| !u.is_empty()));
        images::show(cx, &self.ui.image(cx, ids!(sp_banner)), Some(banner.as_str()).filter(|u| !u.is_empty()));
        self.ui.view(cx, ids!(so_icon_remove)).set_visible(cx, !icon.is_empty());
        self.ui.view(cx, ids!(so_banner_remove)).set_visible(cx, !banner.is_empty());
        self.ui.redraw(cx);
    }

    /// Rails' active invites: the link with Copy, then who made it, when,
    /// uses and expiry; Revoke for its creator and invite managers.
    fn fill_invites(&mut self, cx: &mut Cx) {
        let now = chrono::Utc::now().timestamp();
        let rows: Vec<lists::PersonRow> = self
            .srv
            .invites
            .iter()
            .filter(|i| i.expires_at == 0 || i.expires_at > now)
            .map(|i| {
                let uses = if i.max_uses > 0 { format!("{}/{} uses", i.uses, i.max_uses) } else { format!("{} uses", i.uses) };
                let expiry = if i.expires_at > 0 { format!("expires in {}", time_fmt::in_words(i.expires_at - now)) } else { "Never expires".into() };
                let link: String = i.link.chars().take(56).collect();
                lists::PersonRow {
                    id: i.code.clone(),
                    name: format!("{link}…"),
                    detail: format!("by {} · {} ago · {uses} · {expiry}", i.by, time_fmt::in_words(now - i.created_at)),
                    a: Some("Copy".into()),
                    b: i.can_revoke.then(|| "Revoke".to_owned()),
                }
            })
            .collect();
        self.ui.label(cx, ids!(inv_title)).set_text(cx, &format!("ACTIVE INVITES ({})", rows.len()));
        if let Some(mut l) = self.ui.widget(cx, ids!(srv_invites)).borrow_mut::<lists::PeopleList>() {
            l.rows = rows;
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(srv_invites.list)));
    }

    fn fill_people(&mut self, cx: &mut Cx) {
        let p = self.perms.clone();
        let q = self.ui.text_input(cx, ids!(mem_search)).text().trim().to_lowercase();
        let rows: Vec<backend::MemberInfo> =
            self.srv.members.iter().filter(|m| q.is_empty() || m.name.to_lowercase().contains(&q)).cloned().collect();
        self.ui.label(cx, ids!(srv_members_title)).set_text(cx, &format!("Members ({})", self.srv.members.len()));
        let present: std::collections::HashSet<String> = self.srv.members.iter().map(|m| m.pubkey.clone()).collect();
        let mut selected = 0;
        if let Some(mut l) = self.ui.widget(cx, ids!(srv_members)).borrow_mut::<lists::MemberAdminList>() {
            l.rows = rows;
            l.can_roles = p.manage_roles;
            l.can_kick = p.kick_members;
            l.can_ban = p.ban_members;
            // Whoever left or was removed drops out of the selection.
            l.selected.retain(|pk| present.contains(pk));
            selected = l.selected.len();
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(srv_members.list)));
        self.paint_member_batch(cx, selected);
        let bans: Vec<lists::PersonRow> = self
            .srv
            .bans
            .iter()
            .map(|b| lists::PersonRow {
                id: b.pubkey.clone(),
                name: b.name.clone(),
                detail: if b.reason.is_empty() { "No reason given".into() } else { b.reason.clone() },
                a: p.ban_members.then(|| "Unban".to_owned()),
                b: None,
            })
            .collect();
        if let Some(mut l) = self.ui.widget(cx, ids!(srv_bans)).borrow_mut::<lists::PeopleList>() {
            l.rows = bans;
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(srv_bans.list)));
    }

    /// The Expression pages: counts against Rails' limits, and the lists.
    fn fill_custom(&mut self, cx: &mut Cx) {
        use inferno_core::server::custom::{MAX_EMOJIS, MAX_STICKERS};
        let p = self.perms.clone();
        let (emojis, stickers) = (self.srv.emojis.clone(), self.srv.stickers.clone());
        self.ui.label(cx, ids!(em_title)).set_text(cx, &format!("CUSTOM EMOJIS ({}/{MAX_EMOJIS})", emojis.len()));
        self.ui.label(cx, ids!(st_title)).set_text(cx, &format!("STICKERS ({}/{MAX_STICKERS})", stickers.len()));
        self.ui.view(cx, ids!(em_upload)).set_visible(cx, p.create_emojis || p.manage_emojis);
        self.ui.view(cx, ids!(st_upload)).set_visible(cx, p.create_stickers || p.manage_emojis);
        for (path, items, list) in [(ids!(em_list), emojis, ids!(em_list.list)), (ids!(st_list), stickers, ids!(st_list.list))] {
            if let Some(mut l) = self.ui.widget(cx, path).borrow_mut::<lists::CustomList>() {
                l.items = items;
                l.can_delete = p.manage_emojis;
            }
            lists::redraw_items(cx, &self.ui.portal_list(cx, list));
        }
    }

    /// Rails' batch bar: shown while members are selected.
    fn paint_member_batch(&mut self, cx: &mut Cx, selected: usize) {
        let p = &self.perms;
        let any = p.kick_members || p.ban_members;
        self.ui.view(cx, ids!(mem_select_all)).set_visible(cx, any);
        self.ui.view(cx, ids!(mem_batch)).set_visible(cx, selected > 0);
        self.ui.label(cx, ids!(mem_selected)).set_text(cx, &format!("{selected} selected"));
        self.ui.view(cx, ids!(mem_batch_timeout)).set_visible(cx, p.kick_members);
        self.ui.view(cx, ids!(mem_batch_kick)).set_visible(cx, p.kick_members);
        self.ui.view(cx, ids!(mem_batch_ban)).set_visible(cx, p.ban_members);
        let selectable = self.srv.members.iter().filter(|m| !m.owner && !m.me).count();
        let all = selected > 0 && selected == selectable;
        let b = self.ui.widget(cx, ids!(mem_all_box));
        lists::set_check(cx, &b, all);
        self.ui.redraw(cx);
    }

    fn clear_member_selection(&mut self, cx: &mut Cx) {
        if let Some(mut l) = self.ui.widget(cx, ids!(srv_members)).borrow_mut::<lists::MemberAdminList>() {
            l.selected.clear();
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(srv_members.list)));
        self.paint_member_batch(cx, 0);
    }

    fn selected_members(&self, cx: &mut Cx) -> Vec<String> {
        self.ui.widget(cx, ids!(srv_members)).borrow::<lists::MemberAdminList>().map(|l| l.selected.iter().cloned().collect()).unwrap_or_default()
    }

    /// Whether we may change the selected role: manage_roles, and below our
    /// own highest role (Flutter's hierarchy rule).
    fn role_editable(&self) -> bool {
        self.perms.manage_roles && self.role_drafts.get(self.role_sel).is_some_and(|r| r.everyone || r.position < self.srv.my_rank)
    }

    /// Shows the selected role draft in the editor.
    fn show_role(&mut self, cx: &mut Cx) {
        let Some(r) = self.role_drafts.get(self.role_sel).cloned() else { return };
        let can = self.role_editable();
        self.ui.label(cx, ids!(role_title)).set_text(cx, &r.name);
        // @everyone: permissions only, like Rails.
        self.ui.view(cx, ids!(role_fields)).set_visible(cx, !r.everyone);
        self.ui.widget(cx, ids!(role_everyone_note)).set_visible(cx, r.everyone);
        self.ui.button(cx, ids!(role_delete)).set_visible(cx, can && !r.everyone);
        self.ui.widget(cx, ids!(role_locked)).set_visible(cx, self.perms.manage_roles && !can);
        self.ui.view(cx, ids!(role_tab_members)).set_visible(cx, !r.everyone);
        if r.everyone && self.role_tab == 2 {
            self.role_tab = 0;
        }
        self.ui.text_input(cx, ids!(role_name)).set_text(cx, &r.name);
        self.ui.text_input(cx, ids!(role_color)).set_text(cx, &r.color);
        if let Some(mut l) = self.ui.widget(cx, ids!(role_perms)).borrow_mut::<lists::PermList>() {
            l.granted = r.perms.clone();
            l.enabled = can;
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(role_perms.list)));
        self.paint_role(cx);
        self.show_role_tab(cx);
        self.fill_role_members(cx);
    }

    /// Everything that follows the draft as it's edited: swatch, switches,
    /// preview, the list, and the save bar.
    fn paint_role(&mut self, cx: &mut Cx) {
        let Some(r) = self.role_drafts.get(self.role_sel).cloned() else { return };
        let can = self.role_editable();
        let color = u32::from_str_radix(r.color.trim_start_matches('#'), 16).ok().filter(|_| r.color.len() == 7).unwrap_or(0x99aab5);
        let v = lists::rgba(color, 1.0);
        let mut sw = self.ui.widget(cx, ids!(role_swatch));
        script_apply_eval!(cx, sw, {draw_bg +: {color: #(v)}});
        for path in [ids!(role_pv_group), ids!(role_pv_member), ids!(role_pv_msg)] {
            let mut t = self.ui.widget(cx, path);
            script_apply_eval!(cx, t, {draw_text +: {color: #(v)}});
        }
        let me = self.my_display_name();
        self.ui.label(cx, ids!(role_pv_group)).set_text(cx, &format!("{} — 1", r.name.to_uppercase()));
        self.ui.label(cx, ids!(role_pv_member)).set_text(cx, &me);
        self.ui.label(cx, ids!(role_pv_msg)).set_text(cx, &me);
        let sw = self.ui.widget(cx, ids!(role_hoist.switch));
        lists::set_switch(cx, &sw, r.hoist, can);
        let sw = self.ui.widget(cx, ids!(role_mention.switch));
        lists::set_switch(cx, &sw, r.mentionable, can);
        self.ui.label(cx, ids!(role_title)).set_text(cx, &r.name);
        if let Some(mut l) = self.ui.widget(cx, ids!(role_list)).borrow_mut::<lists::RoleList>() {
            l.roles = self.role_drafts.clone();
            l.selected = self.role_sel;
            l.rank = if self.perms.manage_roles { self.srv.my_rank } else { i64::MIN };
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(role_list.list)));
        let dirty = roles_differ(&self.role_drafts, &self.srv.roles);
        self.ui.view(cx, ids!(role_save_bar)).set_visible(cx, dirty && self.srv_page == 2);
        self.ui.redraw(cx);
    }

    fn my_display_name(&self) -> String {
        self.members
            .iter()
            .find_map(|m| match m {
                backend::MemberRow::Member { name, me: true, .. } => Some(name.clone()),
                _ => None,
            })
            .unwrap_or_else(|| "You".into())
    }

    fn show_role_tab(&mut self, cx: &mut Cx) {
        let tabs: [(&[LiveId], &[LiveId]); 3] = [
            (ids!(role_tab_display), ids!(role_display)),
            (ids!(role_tab_perms), ids!(role_perms_panel)),
            (ids!(role_tab_members), ids!(role_members_panel)),
        ];
        for (i, (tab, panel)) in tabs.into_iter().enumerate() {
            self.ui.view(cx, panel).set_visible(cx, i == self.role_tab);
            let mut pill = self.ui.widget(cx, tab);
            let bg = if i == self.role_tab { theme::tok("gray_600", 1.0) } else { lists::rgba(0, 0.0) };
            script_apply_eval!(cx, pill, {draw_bg +: {color: #(bg)}});
        }
        self.ui.redraw(cx);
    }

    /// Rails' Members tab: everyone, searchable, with Add/Remove for this role.
    fn fill_role_members(&mut self, cx: &mut Cx) {
        let Some(r) = self.role_drafts.get(self.role_sel).cloned() else { return };
        let saved = self.srv.roles.iter().any(|s| s.id == r.id);
        let can = self.role_editable() && saved && !r.everyone;
        let q = self.ui.text_input(cx, ids!(role_member_search)).text().trim().to_lowercase();
        let mut assigned = 0;
        let rows: Vec<lists::PersonRow> = self
            .members
            .iter()
            .filter_map(|m| match m {
                backend::MemberRow::Member { name, pubkey, roles, .. } => {
                    let has = roles.contains(&r.id);
                    assigned += usize::from(has);
                    (q.is_empty() || name.to_lowercase().contains(&q)).then(|| lists::PersonRow {
                        id: pubkey.clone(),
                        name: name.clone(),
                        detail: if has { "Has this role".into() } else { String::new() },
                        a: can.then(|| if has { "Remove".to_owned() } else { "Add".to_owned() }),
                        b: None,
                    })
                }
                _ => None,
            })
            .collect();
        let note = if saved { format!("{assigned} assigned") } else { "Save the role to assign it".into() };
        self.ui.label(cx, ids!(role_member_count)).set_text(cx, &note);
        if let Some(mut l) = self.ui.widget(cx, ids!(role_members)).borrow_mut::<lists::PeopleList>() {
            l.rows = rows;
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(role_members.list)));
    }

    /// Pulls the editor's text fields into the selected draft.
    fn read_role_editor(&mut self, cx: &mut Cx) {
        if !self.role_editable() {
            return;
        }
        let name = self.ui.text_input(cx, ids!(role_name)).text();
        let color = self.ui.text_input(cx, ids!(role_color)).text();
        let perms = self.ui.widget(cx, ids!(role_perms)).borrow::<lists::PermList>().map(|l| l.granted.clone()).unwrap_or_default();
        if let Some(r) = self.role_drafts.get_mut(self.role_sel) {
            if !r.everyone {
                r.name = name;
                r.color = color;
            }
            r.perms = perms;
        }
    }

    /// Drag-reorder: the moved role takes its new place; positions are
    /// reshuffled among the roles we may move only, so roles above us keep
    /// theirs.
    fn move_role(&mut self, cx: &mut Cx, from: usize, to: usize) {
        self.read_role_editor(cx);
        let rank = self.srv.my_rank;
        let movable = |r: &backend::RoleForm| !r.everyone && r.position < rank;
        let mut positions: Vec<i64> = self.role_drafts.iter().filter(|r| movable(r)).map(|r| r.position).collect();
        positions.sort_by(|a, b| b.cmp(a));
        let selected = self.role_drafts.get(self.role_sel).map(|r| r.id.clone());
        let role = self.role_drafts.remove(from);
        let to = if to > from { to - 1 } else { to };
        self.role_drafts.insert(to.min(self.role_drafts.len()), role);
        let mut next = positions.into_iter();
        for r in self.role_drafts.iter_mut().filter(|r| movable(r)) {
            if let Some(p) = next.next() {
                r.position = p;
            }
        }
        self.role_sel = selected.and_then(|id| self.role_drafts.iter().position(|r| r.id == id)).unwrap_or(0);
        self.paint_role(cx);
    }

    fn show_card(&mut self, cx: &mut Cx, card: &backend::Card) {
        let Some(at) = self.card_at.take() else { return };
        self.close_menu(cx);
        self.card = card.clone();
        let c = self.ui.widget(cx, ids!(card));
        let mut bg = c.clone();
        let (c0, c1) = (lists::rgba(card.color, 1.0), lists::rgba(card.color_2, 1.0));
        let banner = theme::tok("gray_700", 1.0);
        script_apply_eval!(cx, bg, {draw_bg +: {c0: #(c0) c1: #(c1) banner: #(banner)}});
        let ring = lists::rgba(card.ring, 1.0);
        let mut w = self.ui.widget(cx, ids!(card.ring));
        script_apply_eval!(cx, w, {draw_bg +: {color: #(ring)}});
        let mut w = self.ui.widget(cx, ids!(card.dot));
        script_apply_eval!(cx, w, {draw_bg +: {border_color: #(ring)}});
        let avatar = lists::rgba(card.avatar, 1.0);
        let mut w = self.ui.widget(cx, ids!(card.ring.avatar));
        script_apply_eval!(cx, w, {draw_bg +: {color: #(avatar)}});
        self.ui.label(cx, ids!(card.ring.avatar.initial)).set_text(cx, &card.initial);
        let img = self.ui.image(cx, ids!(card.ring.avatar.pic));
        images::show(cx, &img, card.picture.as_deref());
        let img = self.ui.image(cx, ids!(card.banner));
        images::show(cx, &img, card.banner.as_deref());
        self.ui.label(cx, ids!(card.name)).set_text(cx, &card.name);
        self.ui.label(cx, ids!(card.tag)).set_text(cx, &card.tag);
        self.ui.label(cx, ids!(card.status)).set_text(cx, &card.status);
        self.ui.widget(cx, ids!(card.status)).set_visible(cx, !card.status.is_empty());
        self.ui.label(cx, ids!(card.about)).set_text(cx, &card.about);
        self.ui.view(cx, ids!(card.about_box)).set_visible(cx, !card.about.is_empty());
        self.ui.view(cx, ids!(card.roles_box)).set_visible(cx, !card.roles.is_empty());
        for (i, chip) in [ids!(r0), ids!(r1), ids!(r2), ids!(r3), ids!(r4), ids!(r5), ids!(r6), ids!(r7), ids!(r8), ids!(r9)]
            .into_iter()
            .enumerate()
        {
            let view = self.ui.view(cx, &[id!(card), chip[0]]);
            match card.roles.get(i) {
                Some((name, color)) => {
                    view.set_visible(cx, true);
                    self.ui.label(cx, &[id!(card), chip[0], id!(label)]).set_text(cx, name);
                    let mut dot = self.ui.widget(cx, &[id!(card), chip[0], id!(dot)]);
                    let c = lists::rgba(*color, 1.0);
                    script_apply_eval!(cx, dot, {draw_bg +: {color: #(c)}});
                }
                None => view.set_visible(cx, false),
            }
        }
        self.ui.view(cx, ids!(card_message)).set_visible(cx, !card.me);
        self.ui.view(cx, ids!(card_friend)).set_visible(cx, !card.me);
        self.ui.label(cx, ids!(card_friend.label)).set_text(cx, Self::card_friend_label(card.friend));
        let since = card.joined_at.map(lists::date_long).unwrap_or_else(|| "Unknown".into());
        self.ui.label(cx, ids!(card.since)).set_text(cx, &since);
        // Keep it on screen; Rails clamps against 400px of height.
        let win = self.ui.view(cx, ids!(card_layer)).area().rect(cx).size;
        let win = if win.x > 0.0 { win } else { dvec2(1400.0, 860.0) };
        let (x, y) = ctxmenu::place((at.x, at.y), (288.0, 400.0), (win.x, win.y));
        let mut w = self.ui.widget(cx, ids!(card));
        script_apply_eval!(cx, w, {margin: mod.prelude.widgets.Inset{left: #(x) top: #(y)}});
        self.ui.view(cx, ids!(card_layer)).set_visible(cx, true);
        self.ui.redraw(cx);
    }

    fn close_card(&mut self, cx: &mut Cx) {
        if self.ui.view(cx, ids!(card_layer)).visible() {
            self.ui.view(cx, ids!(card_layer)).set_visible(cx, false);
            self.ui.redraw(cx);
        }
    }

    /// Switches between a server and Home (DM sidebar, friends, DMs).
    fn set_home(&mut self, cx: &mut Cx, home: bool) {
        self.home = home;
        self.ui.view(cx, ids!(server_side)).set_visible(cx, !home);
        self.ui.view(cx, ids!(dm_side)).set_visible(cx, home);
        self.ui.view(cx, ids!(server_menu)).set_visible(cx, false);
        self.ui.view(cx, ids!(member_col)).set_visible(cx, !home);
        self.ui.view(cx, ids!(member_edge)).set_visible(cx, !home);
        self.ui.view(cx, ids!(search_panel)).set_visible(cx, false);
        for path in [ids!(pins_btn), ids!(invite_btn), ids!(search_bar), ids!(topic_divider)] {
            self.ui.view(cx, path).set_visible(cx, !home);
        }
        self.ui.widget(cx, ids!(channel_topic)).set_visible(cx, !home);
        if !home {
            self.dm_with = None;
            self.ui.view(cx, ids!(friends_page)).set_visible(cx, false);
            self.ui.view(cx, ids!(chat_col)).set_visible(cx, true);
            self.ui.view(cx, ids!(dm_request)).set_visible(cx, false);
            self.ui.view(cx, ids!(composer_box)).set_visible(cx, true);
        }
        let mut btn = self.ui.widget(cx, ids!(home_btn));
        let bg = if home { theme::tok("accent", 1.0) } else { theme::tok("gray_700", 1.0) };
        script_apply_eval!(cx, btn, {draw_bg +: {color: #(bg)}});
        if let Some(mut rail) = self.ui.widget(cx, ids!(rail)).borrow_mut::<lists::RailList>() {
            if home {
                rail.selected = None;
            }
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(rail.list)));
        self.ui.redraw(cx);
    }

    /// The friends page, on `tab`.
    fn show_friends(&mut self, cx: &mut Cx, tab: usize) {
        self.friends_tab = tab;
        self.dm_with = None;
        self.ui.view(cx, ids!(friends_page)).set_visible(cx, true);
        self.ui.view(cx, ids!(chat_col)).set_visible(cx, false);
        self.ui.view(cx, ids!(find_box)).set_visible(cx, tab == 4);
        for (i, path) in [ids!(tab_online), ids!(tab_all), ids!(tab_pending), ids!(tab_blocked)].into_iter().enumerate() {
            let mut pill = self.ui.widget(cx, path);
            let bg = if i == tab { theme::tok("gray_600", 1.0) } else { lists::rgba(0, 0.0) };
            script_apply_eval!(cx, pill, {draw_bg +: {color: #(bg)}});
        }
        self.fill_friends(cx);
        self.fill_dm_sidebar(cx);
    }

    fn fill_friends(&mut self, cx: &mut Cx) {
        use lists::{FriendKind as K, FriendRow as R};
        let h = &self.home_data;
        let people = |list: &[backend::Person], sub: &str, kind: K| -> Vec<R> {
            list.iter().map(|p| R::Person { person: p.clone(), sub: sub.into(), kind }).collect()
        };
        let mut rows = Vec::new();
        match self.friends_tab {
            // Presence isn't published yet, so Online lists everyone, as All.
            0 | 1 => {
                let title = if self.friends_tab == 0 { "ONLINE" } else { "ALL CONTACTS" };
                if h.friends.is_empty() {
                    rows.push(R::Empty("You don't have any contacts yet. Add some!".into()));
                } else {
                    rows.push(R::Header(format!("{title} — {}", h.friends.len())));
                    rows.extend(people(&h.friends, "Friend", K::Friend));
                }
            }
            2 => {
                if !h.incoming.is_empty() {
                    rows.push(R::Header(format!("INCOMING — {}", h.incoming.len())));
                    rows.extend(people(&h.incoming, "Incoming Friend Request", K::Incoming));
                }
                if !h.outgoing.is_empty() {
                    rows.push(R::Header(format!("OUTGOING — {}", h.outgoing.len())));
                    rows.extend(people(&h.outgoing, "Outgoing Friend Request", K::Outgoing));
                }
                if rows.is_empty() {
                    rows.push(R::Empty("There are no pending friend requests.".into()));
                }
            }
            3 => {
                if h.blocked.is_empty() {
                    rows.push(R::Empty("You haven't blocked anyone.".into()));
                } else {
                    rows.push(R::Header(format!("BLOCKED — {}", h.blocked.len())));
                    rows.extend(people(&h.blocked, "Blocked", K::Blocked));
                }
            }
            _ => {
                let friends: Vec<&str> = h.friends.iter().map(|p| p.pubkey.as_str()).collect();
                for p in &self.found {
                    let kind = if friends.contains(&p.pubkey.as_str()) { K::Friend } else { K::Found };
                    rows.push(R::Person { person: p.clone(), sub: String::new(), kind });
                }
            }
        }
        if let Some(mut l) = self.ui.widget(cx, ids!(friend_list)).borrow_mut::<lists::FriendList>() {
            l.rows = rows;
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(friend_list.list)));
        let n = h.incoming.len();
        self.ui.view(cx, ids!(pending_badge)).set_visible(cx, n > 0);
        self.ui.label(cx, ids!(pending_badge.count)).set_text(cx, &n.to_string());
        self.ui.redraw(cx);
    }

    fn fill_dm_sidebar(&mut self, cx: &mut Cx) {
        let friends_active = self.dm_with.is_none();
        let me_hex = self.my_hex();
        for (path, active) in [(ids!(friends_link), friends_active), (ids!(saved_link), self.dm_with.as_deref() == Some(me_hex.as_str()))] {
            let mut link = self.ui.widget(cx, path);
            let bg = if active { theme::tok("gray_700", 1.0) } else { lists::rgba(0, 0.0) };
            script_apply_eval!(cx, link, {draw_bg +: {color: #(bg)}});
            let mut label = self.ui.widget(cx, &[path[0], id!(label)]);
            let fg = if active { lists::rgba(0xffffff, 1.0) } else { theme::tok("gray_400", 1.0) };
            script_apply_eval!(cx, label, {draw_text +: {color: #(fg)}});
        }
        if let Some(mut l) = self.ui.widget(cx, ids!(dms)).borrow_mut::<lists::DmList>() {
            // Saved Messages has its own link above the list.
            l.rows = self.home_data.conversations.iter().filter(|c| c.person.pubkey != me_hex).cloned().collect();
            l.selected = self.dm_with.clone();
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(dms.list)));
    }

    fn my_hex(&self) -> String {
        inferno_core::nostr::prelude::PublicKey::parse(&self.npub).map(|p| p.to_hex()).unwrap_or_default()
    }

    /// Rails' friend request bar: one incoming request at a time.
    fn fill_request_bar(&mut self, cx: &mut Cx) {
        let n = self.home_data.incoming.len();
        self.ui.view(cx, ids!(friend_bar)).set_visible(cx, n > 0);
        if n == 0 {
            return;
        }
        self.bar_index = self.bar_index.min(n - 1);
        let p = self.home_data.incoming[self.bar_index].clone();
        self.ui.label(cx, ids!(fb_text)).set_text(cx, &format!("{} wants to be friends", p.name));
        self.ui.label(cx, ids!(fb_count)).set_text(cx, &format!("{}/{}", self.bar_index + 1, n));
        self.ui.label(cx, ids!(fb_avatar.initial)).set_text(cx, &p.initial);
        let mut a = self.ui.widget(cx, ids!(fb_avatar));
        let c = lists::rgba(p.avatar, 1.0);
        script_apply_eval!(cx, a, {draw_bg +: {color: #(c)}});
        self.ui.redraw(cx);
    }

    fn open_dm(&mut self, cx: &mut Cx, pubkey: String) {
        self.close_card(cx);
        if !self.home {
            self.set_home(cx, true);
        }
        self.dm_with = Some(pubkey.clone());
        self.ui.view(cx, ids!(friends_page)).set_visible(cx, false);
        self.ui.view(cx, ids!(chat_col)).set_visible(cx, true);
        self.send(backend::Command::OpenDm(pubkey));
        self.fill_dm_sidebar(cx);
    }

    /// What the card's friend button says and does (Rails' four states).
    fn card_friend_label(friend: Friend) -> &'static str {
        match friend {
            Friend::None => "Add Friend",
            Friend::Outgoing => "Request Sent",
            Friend::Incoming => "Accept Request",
            Friend::Accepted => "Remove Friend",
        }
    }

    /// The profile card editor's colours, from the hex fields.
    fn paint_profile_editor(&mut self, cx: &mut Cx) {
        let hex = |s: String| {
            let h = s.trim().trim_start_matches('#').to_owned();
            u32::from_str_radix(&h, 16).ok().filter(|_| h.len() == 6)
        };
        let c1 = hex(self.ui.text_input(cx, ids!(p_color)).text());
        let c2 = hex(self.ui.text_input(cx, ids!(p_color_2)).text());
        let (a, b) = (c1.unwrap_or(0x1e1c1b), c2.or(c1).unwrap_or(0x1e1c1b));
        let (v0, v1, banner) = (lists::rgba(a, 1.0), lists::rgba(b, 1.0), theme::tok("gray_700", 1.0));
        let mut card = self.ui.widget(cx, ids!(profile_editor));
        script_apply_eval!(cx, card, {draw_bg +: {c0: #(v0) c1: #(v1) banner: #(banner)}});
        let mut ring = self.ui.widget(cx, ids!(ed_avatar));
        script_apply_eval!(cx, ring, {draw_bg +: {color: #(v1)}});
        let mut face = self.ui.widget(cx, ids!(ed_face));
        script_apply_eval!(cx, face, {draw_bg +: {color: #(v0)}});
        let name = self.ui.text_input(cx, ids!(p_display)).text();
        let name = if name.trim().is_empty() { self.ui.text_input(cx, ids!(p_username)).text() } else { name };
        let initial = name.trim().chars().next().map(|c| c.to_uppercase().to_string()).unwrap_or_else(|| "?".into());
        self.ui.label(cx, ids!(ed_face.initial)).set_text(cx, &initial);
        self.ui.redraw(cx);
    }

    /// Shows the saved (or just uploaded) pictures on the editor card.
    fn show_profile_pictures(&mut self, cx: &mut Cx) {
        let pic = Some(self.draft_picture.clone()).filter(|u| !u.is_empty());
        let banner = Some(self.draft_banner.clone()).filter(|u| !u.is_empty());
        let img = self.ui.image(cx, ids!(ed_face.pic));
        images::show(cx, &img, pic.as_deref());
        let img = self.ui.image(cx, ids!(ed_banner_img));
        images::show(cx, &img, banner.as_deref());
    }

    /// Where notes about `purpose`'s picture go.
    fn picture_note(&mut self, cx: &mut Cx, purpose: uploads::Purpose, text: &str) {
        if purpose.custom() {
            let kind = if text.starts_with('⚠') { Toast::Error } else { Toast::Info };
            self.toast(cx, text.trim_start_matches("⚠ "), kind);
            return;
        }
        let path: &[LiveId] = if purpose.server() { ids!(so_note) } else { ids!(profile_note) };
        self.ui.label(cx, path).set_text(cx, text);
    }

    /// A picked file: pictures go to the crop editor, emoji and stickers
    /// are staged for upload.
    fn picked_file(&mut self, cx: &mut Cx, purpose: uploads::Purpose, bytes: &[u8]) {
        if purpose.custom() {
            self.stage_custom(cx, purpose == uploads::Purpose::Sticker, bytes.to_vec());
        } else {
            self.open_crop(cx, purpose, bytes);
        }
    }

    /// Rails' upload row: check type and size, preview it, and name it from
    /// the file if there's no name yet.
    fn stage_custom(&mut self, cx: &mut Cx, sticker: bool, bytes: Vec<u8>) {
        let mime = if bytes.starts_with(b"\x89PNG") {
            "image/png"
        } else if bytes.starts_with(b"GIF8") {
            "image/gif"
        } else if bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
            "image/webp"
        } else {
            self.toast(cx, "Use a PNG, GIF or WebP image.", Toast::Error);
            return;
        };
        let max = if sticker { 512 * 1024 } else { 256 * 1024 };
        if bytes.len() > max {
            self.toast(cx, &format!("That file is over {} KB.", max / 1024), Toast::Error);
            return;
        }
        let (img, placeholder): (&[LiveId], &[LiveId]) =
            if sticker { (ids!(st_preview.img), ids!(st_preview.plus)) } else { (ids!(em_preview.img), ids!(em_preview.plus)) };
        let image = self.ui.image(cx, img);
        match decode_image_from_data(&bytes) {
            Ok(decoded) => {
                let texture = decoded.into_new_texture(cx);
                image.set_texture(cx, Some(texture));
                image.set_visible(cx, true);
                self.ui.widget(cx, placeholder).set_visible(cx, false);
            }
            // WebP may not decode here; it still uploads.
            Err(_) => {
                image.set_visible(cx, false);
                self.ui.label(cx, placeholder).set_text(cx, "✓");
            }
        }
        if let Some(name) = self.custom_file_name.take() {
            let field: &[LiveId] = if sticker { ids!(st_name) } else { ids!(em_name) };
            if self.ui.text_input(cx, field).text().trim().is_empty() {
                let stem = name.rsplit_once('.').map_or(name.as_str(), |(s, _)| s).to_owned();
                let auto = if sticker {
                    stem.replace(['-', '_'], " ").split_whitespace().map(|w| {
                        let mut c = w.chars();
                        c.next().map(|f| f.to_uppercase().chain(c).collect::<String>()).unwrap_or_default()
                    }).collect::<Vec<_>>().join(" ")
                } else {
                    let mut out = String::new();
                    for ch in stem.to_lowercase().chars() {
                        let ch = if ch.is_ascii_alphanumeric() { ch } else { '_' };
                        if !(ch == '_' && out.ends_with('_')) {
                            out.push(ch);
                        }
                    }
                    out.trim_matches('_').chars().take(32).collect()
                };
                self.ui.text_input(cx, field).set_text(cx, &auto);
            }
        }
        self.custom_staged = Some((sticker, bytes, mime));
        self.ui.redraw(cx);
    }

    /// Upload: the staged file goes to Blossom, then into the list.
    fn upload_custom(&mut self, cx: &mut Cx, sticker: bool) {
        let staged = self.custom_staged.take_if(|(s, _, _)| *s == sticker);
        let Some((_, bytes, mime)) = staged else {
            self.toast(cx, "Pick an image first.", Toast::Error);
            return;
        };
        let name = self.ui.text_input(cx, if sticker { ids!(st_name) } else { ids!(em_name) }).text().trim().to_owned();
        let ok = if sticker {
            !name.is_empty() && name.chars().count() <= 50
        } else {
            inferno_core::server::custom::valid_emoji_name(&name)
        };
        if !ok {
            let msg = if sticker { "Sticker names are 1-50 characters." } else { "Emoji names are lowercase letters, digits and _ (up to 32)." };
            self.toast(cx, msg, Toast::Error);
            self.custom_staged = Some((sticker, bytes, mime));
            return;
        }
        let description = if sticker { self.ui.text_input(cx, ids!(st_desc)).text() } else { String::new() };
        self.custom_pending = Some((name, description));
        let purpose = if sticker { uploads::Purpose::Sticker } else { uploads::Purpose::Emoji };
        let (id, sha256) = self.uploads.start(purpose, bytes, mime);
        self.send(backend::Command::UploadAuth { id, sha256 });
        self.toast(cx, "Uploading…", Toast::Info);
    }

    fn clear_custom_form(&mut self, cx: &mut Cx, sticker: bool) {
        let (img, plus, fields): (&[LiveId], &[LiveId], &[&[LiveId]]) = if sticker {
            (ids!(st_preview.img), ids!(st_preview.plus), &[ids!(st_name), ids!(st_desc)])
        } else {
            (ids!(em_preview.img), ids!(em_preview.plus), &[ids!(em_name)])
        };
        self.ui.image(cx, img).set_visible(cx, false);
        self.ui.widget(cx, plus).set_visible(cx, true);
        self.ui.label(cx, plus).set_text(cx, "+");
        for f in fields {
            self.ui.text_input(cx, f).set_text(cx, "");
        }
        self.ui.redraw(cx);
    }

    /// Opens the system picker for a picture.
    fn pick_picture(&mut self, cx: &mut Cx, purpose: uploads::Purpose) {
        let (id, title) = match purpose {
            uploads::Purpose::Avatar => (live_id!(pick_avatar), "Choose a picture"),
            uploads::Purpose::Banner => (live_id!(pick_banner), "Choose a banner"),
            uploads::Purpose::ServerIcon => (live_id!(pick_srv_icon), "Choose a server icon"),
            uploads::Purpose::ServerBanner => (live_id!(pick_srv_banner), "Choose a server banner"),
            uploads::Purpose::Emoji => (live_id!(pick_emoji), "Choose an emoji image"),
            uploads::Purpose::Sticker => (live_id!(pick_sticker), "Choose a sticker image"),
        };
        // UI tests can't drive the system dialog: INFERNO_TEST_PICK=<file>
        // stands in for the user's choice.
        if let Ok(path) = std::env::var("INFERNO_TEST_PICK") {
            match std::fs::read(&path) {
                Ok(bytes) => {
                    self.custom_file_name = std::path::Path::new(&path).file_name().map(|n| n.to_string_lossy().into_owned());
                    self.picked_file(cx, purpose, &bytes)
                }
                Err(e) => self.picture_note(cx, purpose, &format!("⚠ {path}: {e}")),
            }
            return;
        }
        let dialog = FileDialog::new()
            .set_id(id)
            .set_title(title.into())
            .add_filter(
                "Images".into(),
                if purpose.custom() { vec!["png".into(), "gif".into(), "webp".into()] } else { ["png", "jpg", "jpeg", "gif", "webp", "bmp"].map(String::from).to_vec() },
            )
            .want_bytes(true);
        cx.open_select_file_dialog(dialog);
    }

    /// A picked file: decode it into the editor (Rails' crop modal).
    fn open_crop(&mut self, cx: &mut Cx, purpose: uploads::Purpose, bytes: &[u8]) {
        const MAX_BYTES: usize = 20 * 1024 * 1024;
        if bytes.len() > MAX_BYTES {
            self.picture_note(cx, purpose, "⚠ That file is over 20 MB.");
            return;
        }
        let image = match decode_image_from_data(bytes) {
            Ok(i) if i.width > 0 && i.height > 0 => i,
            _ => {
                self.picture_note(cx, purpose, "⚠ That doesn't look like an image this app can read.");
                return;
            }
        };
        let target = purpose.target();
        let view_h = if target == Target::Banner { 200.0 } else { 300.0 };
        let crop = Crop::new(target, (image.width as f64, image.height as f64), (480.0, view_h));
        let pixels = image.data.clone();
        let texture = image.into_new_texture(cx);
        self.ui.image(cx, ids!(crop_img)).set_texture(cx, Some(texture));
        let mut view = self.ui.widget(cx, ids!(crop_view));
        script_apply_eval!(cx, view, {height: #(view_h)});
        let shape = match target {
            Target::Avatar => 1.0,
            Target::Icon => 2.0,
            Target::Banner => 0.0,
        };
        let mut mask = self.ui.widget(cx, ids!(crop_mask));
        script_apply_eval!(cx, mask, {draw_bg +: {circle: #(shape)}});
        let title = match purpose {
            uploads::Purpose::Avatar => "Edit Avatar",
            uploads::Purpose::Banner => "Edit Banner",
            uploads::Purpose::ServerIcon => "Edit Server Icon",
            uploads::Purpose::ServerBanner => "Edit Server Banner",
            uploads::Purpose::Emoji | uploads::Purpose::Sticker => "Edit Image",
        };
        self.ui.label(cx, ids!(crop_title)).set_text(cx, title);
        self.ui.slider(cx, ids!(crop_zoom)).set_value(cx, 1.0);
        self.crop = Some((crop, pixels, purpose));
        self.layout_crop(cx);
        self.ui.modal(cx, ids!(crop_dialog)).open(cx);
    }

    /// Places the picture in the editor viewport from the crop state.
    fn layout_crop(&mut self, cx: &mut Cx) {
        let Some((crop, _, _)) = &self.crop else { return };
        let s = crop.scale();
        let (w, h, x, y) = (crop.src.0 * s, crop.src.1 * s, crop.offset.0, crop.offset.1);
        let mut img = self.ui.widget(cx, ids!(crop_img));
        script_apply_eval!(cx, img, {width: #(w) height: #(h) margin: mod.prelude.widgets.Inset{left: #(x) top: #(y)}});
        self.ui.redraw(cx);
    }

    /// Where `purpose`'s picture shows while it's being edited.
    fn picture_preview(purpose: uploads::Purpose) -> &'static [LiveId] {
        match purpose {
            uploads::Purpose::Avatar => ids!(ed_face.pic),
            uploads::Purpose::Banner => ids!(ed_banner_img),
            uploads::Purpose::ServerIcon => ids!(sp_icon.pic),
            uploads::Purpose::ServerBanner => ids!(sp_banner),
            uploads::Purpose::Emoji => ids!(em_preview.img),
            uploads::Purpose::Sticker => ids!(st_preview.img),
        }
    }

    /// Apply: bake the crop, show it at once, and upload it.
    fn apply_crop(&mut self, cx: &mut Cx) {
        let Some((crop, pixels, purpose)) = self.crop.take() else { return };
        let png = match crop.encode(&pixels) {
            Ok(p) => p,
            Err(e) => {
                self.picture_note(cx, purpose, &format!("⚠ Couldn't prepare the picture: {e}"));
                return;
            }
        };
        let (w, h) = crop.output_size();
        if let Ok(buffer) = ImageBuffer::new(&crop.render(&pixels), w, h) {
            let texture = buffer.into_new_texture(cx);
            let img = self.ui.image(cx, Self::picture_preview(purpose));
            img.set_texture(cx, Some(texture));
            img.set_visible(cx, true);
        }
        let (id, sha256) = self.uploads.start(purpose, png, "image/png");
        self.send(backend::Command::UploadAuth { id, sha256 });
        self.picture_note(cx, purpose, "Uploading…");
        self.ui.modal(cx, ids!(crop_dialog)).close(cx);
        self.ui.redraw(cx);
    }

    fn upload_done(&mut self, cx: &mut Cx, done: uploads::Done) {
        match done {
            uploads::Done::Uploaded { purpose, url } => {
                match purpose {
                    uploads::Purpose::Avatar => self.draft_picture = url,
                    uploads::Purpose::Banner => self.draft_banner = url,
                    uploads::Purpose::ServerIcon => self.srv_icon = url,
                    uploads::Purpose::ServerBanner => self.srv_banner = url,
                    uploads::Purpose::Emoji | uploads::Purpose::Sticker => {
                        let sticker = purpose == uploads::Purpose::Sticker;
                        if let Some((name, description)) = self.custom_pending.take() {
                            self.send(if sticker {
                                backend::Command::AddSticker { name, description, url }
                            } else {
                                backend::Command::AddEmoji { name, url }
                            });
                        }
                        self.clear_custom_form(cx, sticker);
                        return;
                    }
                }
                if purpose.server() {
                    self.paint_server_preview(cx);
                }
                self.picture_note(cx, purpose, "Uploaded. Save Changes to keep it.");
            }
            uploads::Done::Failed { purpose, error } => {
                self.picture_note(cx, purpose, &format!("⚠ Upload failed: {error}"));
            }
        }
    }

    /// Which picker a pick or a rebuild is for.
    fn picker_paths(status: bool) -> (&'static [LiveId], &'static [LiveId]) {
        if status { (ids!(status_picker), ids!(status_picker.items)) } else { (ids!(composer_picker), ids!(composer_picker.items)) }
    }

    /// Custom emoji are allowed in DMs and where the role allows them.
    fn picker_custom_ok(&self) -> bool {
        self.home || self.perms.send_custom_emojis
    }

    fn refresh_picker(&mut self, cx: &mut Cx, status: bool) {
        let (panel, items) = Self::picker_paths(status);
        let search = self.ui.text_input(cx, &[panel[0], id!(search)]).text();
        let stickers_ok = !status && (self.home || self.perms.send_custom_stickers);
        let gifs_ok = !status && (self.home || self.perms.send_gifs);
        if (!stickers_ok && self.picker_tab == PICKER_STICKERS) || (!gifs_ok && self.picker_tab == PICKER_GIFS) {
            self.picker_tab = PICKER_EMOJI;
        }
        let on_gifs = !status && self.picker_tab == PICKER_GIFS;
        self.ui.view(cx, &[panel[0], id!(gif_bar)]).set_visible(cx, on_gifs && self.gif_view != GifView::Home);
        self.ui.view(cx, &[panel[0], id!(gif_link)]).set_visible(cx, on_gifs && self.gif_view == GifView::Favorites);
        if on_gifs {
            let title = match &self.gif_view {
                GifView::Home => String::new(),
                GifView::Favorites => "🔥 Favorites".into(),
                GifView::Collection(id) => {
                    format!("📁 {}", self.gif_collections.iter().find(|c| c.id == *id).map(|c| c.name.as_str()).unwrap_or(""))
                }
            };
            self.ui.label(cx, &[panel[0], id!(gif_title)]).set_text(cx, &title);
        } else {
            self.ui.view(cx, &[panel[0], id!(new_collection)]).set_visible(cx, false);
        }
        let rows = if on_gifs {
            picker::gif_rows(&self.gif_view, &search, &self.gif_favorites, &self.gif_collections)
        } else if status || self.picker_tab == PICKER_EMOJI {
            picker::emoji_rows(&search, &self.picker_frequent, &self.emoji_sets, status || self.picker_custom_ok(), &self.picker_collapsed)
        } else {
            picker::sticker_rows(&search, &self.emoji_sets, &self.picker_collapsed)
        };
        if let Some(mut l) = self.ui.widget(cx, items).borrow_mut::<lists::PickerList>() {
            l.rows = rows;
        }
        lists::redraw_items(cx, &self.ui.portal_list(cx, &[items[0], items[1], id!(list)]));
        if !status {
            // Rails showed "no permission" text; tabs you can't use are hidden (Flutter).
            self.ui.view(cx, ids!(composer_picker.tab_stickers)).set_visible(cx, stickers_ok);
            self.ui.view(cx, ids!(composer_picker.tab_gifs)).set_visible(cx, gifs_ok);
            for (path, tab) in [
                (ids!(composer_picker.tab_gifs), PICKER_GIFS),
                (ids!(composer_picker.tab_stickers), PICKER_STICKERS),
                (ids!(composer_picker.tab_emoji), PICKER_EMOJI),
            ] {
                let on = self.picker_tab == tab;
                self.ui.view(cx, &[path[0], path[1], id!(line)]).set_visible(cx, on);
                let mut label = self.ui.widget(cx, &[path[0], path[1], id!(label)]);
                let c = if on { lists::rgba(0xffffff, 1.0) } else { theme::tok("gray_400", 1.0) };
                script_apply_eval!(cx, label, {draw_text +: {color: #(c)}});
            }
        }
        self.ui.redraw(cx);
    }

    fn set_composer_picker(&mut self, cx: &mut Cx, open: bool) {
        self.ui.view(cx, ids!(composer_picker)).set_visible(cx, open);
        if open {
            self.refresh_picker(cx, false);
            if let Some(mut s) = self.ui.text_input(cx, ids!(composer_picker.search)).borrow_mut() {
                s.take_key_focus(cx);
            }
        }
        self.ui.redraw(cx);
    }

    fn open_status_picker(&mut self, cx: &mut Cx) {
        let r = self.ui.view(cx, ids!(p_status_emoji)).area().rect(cx);
        let (x, y) = (r.pos.x, r.pos.y + r.size.y + 6.0);
        let mut panel = self.ui.widget(cx, ids!(status_picker));
        script_apply_eval!(cx, panel, {margin: mod.prelude.widgets.Inset{left: #(x) top: #(y)}});
        self.ui.view(cx, ids!(status_layer)).set_visible(cx, true);
        self.ui.text_input(cx, ids!(status_picker.search)).set_text(cx, "");
        self.refresh_picker(cx, true);
    }

    fn close_pickers(&mut self, cx: &mut Cx) {
        self.ui.view(cx, ids!(composer_picker)).set_visible(cx, false);
        self.ui.view(cx, ids!(status_layer)).set_visible(cx, false);
        self.ui.redraw(cx);
    }

    /// Shows the status emoji on its button: unicode as text, custom as image.
    fn show_status_emoji(&mut self, cx: &mut Cx) {
        let e = self.status_emoji.clone();
        let custom = e.strip_prefix(':').and_then(|x| x.strip_suffix(':')).and_then(|name| {
            self.emoji_sets.iter().flat_map(|s| &s.emojis).find(|(n, _)| n == name).map(|(_, u)| u.clone())
        });
        let label = if e.is_empty() { "🙂".to_owned() } else if custom.is_some() { String::new() } else { e.clone() };
        self.ui.label(cx, ids!(p_status_emoji.label)).set_text(cx, &label);
        let img = self.ui.image(cx, ids!(p_status_emoji.img));
        images::show(cx, &img, custom.as_deref());
    }

    fn picked(&mut self, cx: &mut Cx, status: bool, pick: lists::Pick) {
        match pick {
            lists::Pick::Toggle(key) => {
                if !self.picker_collapsed.remove(&key) {
                    self.picker_collapsed.insert(key);
                }
                picker::save(&self.picker_frequent, &self.picker_collapsed, self.picker_tab);
                self.refresh_picker(cx, status);
            }
            lists::Pick::Cell(cell) => {
                picker::record_use(&mut self.picker_frequent, cell.clone());
                picker::save(&self.picker_frequent, &self.picker_collapsed, self.picker_tab);
                if status {
                    self.status_emoji = cell.text();
                    self.show_status_emoji(cx);
                } else {
                    // At the caret, as Rails inserts it.
                    let composer = self.ui.rich_input(cx, ids!(composer));
                    let text = composer.text();
                    let at = composer.borrow().map(|i| i.selection().cursor.index).unwrap_or(text.len()).min(text.len());
                    let at = if text.is_char_boundary(at) { at } else { text.len() };
                    let insert = cell.text();
                    let new = format!("{}{}{}", &text[..at], insert, &text[at..]);
                    composer.set_text(cx, &new);
                    composer.set_cursor(
                        cx,
                        makepad_widgets::makepad_draw::text::selection::Cursor { index: at + insert.len(), prefer_next_row: false },
                        false,
                    );
                    self.focus_composer(cx);
                }
                self.close_pickers(cx);
            }
            lists::Pick::Sticker(_, url) => {
                self.send(backend::Command::SendSticker(url));
                self.close_pickers(cx);
            }
            lists::Pick::Tile(tile) => {
                use picker::GifTile;
                match tile {
                    GifTile::Favorites(_) => self.gif_view = GifView::Favorites,
                    GifTile::Collection { id, .. } => self.gif_view = GifView::Collection(id),
                    GifTile::Trending => self.toast(cx, "Trending GIFs need a Tenor API key, which isn't set up yet.", Toast::Info),
                    GifTile::NewCollection => {
                        self.ui.view(cx, ids!(composer_picker.new_collection)).set_visible(cx, true);
                        if let Some(mut i) = self.ui.text_input(cx, ids!(composer_picker.collection_name)).borrow_mut() {
                            i.take_key_focus(cx);
                        }
                    }
                }
                self.refresh_picker(cx, false);
            }
            lists::Pick::Gif(gif) => {
                self.send(backend::Command::Send { text: gif.url, reply_to: None, spoiler: false });
                self.close_pickers(cx);
            }
            lists::Pick::Fire(gif) => self.send(backend::Command::ToggleGifFavorite(gif)),
            lists::Pick::GifMenu(gif, at) => {
                use ctxmenu::{Action as A, Item};
                let mut items = vec![Item::new(if self.gif_favorites.iter().any(|g| g.url == gif.url) { "Remove from Favorites" } else { "Add to Favorites" }, A::GifFavorite(gif.clone()))];
                if !self.gif_collections.is_empty() {
                    items.push(Item::Separator);
                }
                for c in &self.gif_collections {
                    let label = if c.gifs.iter().any(|g| g.url == gif.url) { format!("Remove from {}", c.name) } else { format!("Add to {}", c.name) };
                    items.push(Item::new(label, A::GifCollection { id: c.id.clone(), gif: gif.clone() }));
                }
                items.push(Item::Separator);
                items.push(Item::new("Copy Link", A::Copy(gif.url.clone())));
                self.open_menu(cx, items, at);
            }
            lists::Pick::TileMenu(id, at) => {
                use ctxmenu::{Action as A, Item};
                self.open_menu(cx, vec![Item::danger("Delete Collection", A::DeleteGifCollection(id))], at);
            }
        }
    }

    fn show_search_panel(&mut self, cx: &mut Cx, open: bool) {
        self.ui.view(cx, ids!(search_panel)).set_visible(cx, open);
        self.ui.view(cx, ids!(member_col)).set_visible(cx, !open);
        self.ui.view(cx, ids!(member_edge)).set_visible(cx, !open);
        self.ui.redraw(cx);
    }

    /// A notification card, top right (Rails' toast). Empty text does
    /// nothing (callers used to clear the old notice row with it).
    fn notice(&mut self, cx: &mut Cx, text: &str) {
        self.toast(cx, text, Toast::Info);
    }

    fn toast(&mut self, cx: &mut Cx, text: &str, kind: Toast) {
        let text = text.trim().trim_start_matches('⚠').trim();
        if text.is_empty() {
            return;
        }
        // The same message again just stays up longer.
        self.toasts.retain(|(t, _, _)| t != text);
        self.toasts.push((text.to_owned(), kind, std::time::Instant::now() + std::time::Duration::from_secs(4)));
        while self.toasts.len() > TOAST_SLOTS.len() {
            self.toasts.remove(0);
        }
        self.show_toasts(cx);
        if self.toast_timer.is_empty() {
            self.toast_timer = cx.start_interval(0.25);
        }
    }

    fn show_toasts(&mut self, cx: &mut Cx) {
        for (i, slot) in TOAST_SLOTS.iter().enumerate() {
            let view = self.ui.view(cx, slot);
            match self.toasts.get(i) {
                Some((text, kind, _)) => {
                    view.set_visible(cx, true);
                    self.ui.label(cx, &[slot[0], id!(label)]).set_text(cx, text);
                    let color = match kind {
                        Toast::Success => lists::rgba(0x16a34a, 1.0),
                        Toast::Error => theme::tok("danger", 1.0),
                        Toast::Info => theme::tok("gray_800", 1.0),
                    };
                    let mut w = self.ui.widget(cx, slot);
                    script_apply_eval!(cx, w, {draw_bg +: {color: #(color)}});
                }
                None => view.set_visible(cx, false),
            }
        }
        self.ui.redraw(cx);
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
            Update::Server { gid, name, sidebar, members, perms, roles, categories, channels } => {
                self.perms = perms.clone();
                self.categories = categories.clone();
                self.server_name = name.clone();
                self.roles = roles.clone();
                self.channel_forms = channels.clone();
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
                    list.can_manage = perms.manage_channels;
                }
                lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(channels.list)));
                self.members = members.clone();
                if self.ui.view(cx, ids!(srv_settings)).visible() {
                    self.fill_people(cx);
                    self.fill_role_members(cx);
                }
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
            Update::Timeline { gid, channel_id, rows, can_pin, mentions } => {
                let key = (gid.clone(), channel_id.clone());
                let new_channel = self.showing.as_ref() != Some(&key);
                self.showing = Some(key);
                if new_channel {
                    self.clear_bars(cx);
                    self.ui.view(cx, ids!(pins_panel)).set_visible(cx, false);
                }
                let jump = self.pending_jump.take_if(|(ch, _)| ch == channel_id).map(|(_, id)| id);
                if let Some(mut list) = self.ui.widget(cx, ids!(messages)).borrow_mut::<message_list::MessageList>() {
                    list.can_pin = *can_pin;
                    list.no_reply = gid == "@dm";
                    list.mentions = mentions.iter().cloned().collect();
                    list.set_rows(cx, rows.clone(), new_channel && jump.is_none());
                    if let Some(id) = jump {
                        list.jump_to(cx, &id);
                    }
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
            Update::Discovery(listings) => {
                if let Some(mut l) = self.ui.widget(cx, ids!(discover_list)).borrow_mut::<lists::DiscoverList>() {
                    l.searching = false;
                    l.servers = listings.clone();
                }
                lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(discover_list.list)));
            }
            Update::Invite(link) => {
                cx.copy_to_clipboard(link);
                self.toast(cx, "Invite link copied.", Toast::Success);
            }
            Update::Profile(p) => {
                for (path, value) in [
                    (ids!(p_display), &p.display_name),
                    (ids!(p_username), &p.username),
                    (ids!(p_about), &p.about),
                    (ids!(p_status), &p.status),
                    (ids!(p_color), &p.color),
                    (ids!(p_color_2), &p.color_2),
                ] {
                    self.ui.text_input(cx, path).set_text(cx, value);
                }
                self.draft_picture = p.picture.clone();
                self.draft_banner = p.banner.clone();
                self.status_emoji = p.status_emoji.clone();
                self.show_status_emoji(cx);
                self.paint_profile_editor(cx);
                self.show_profile_pictures(cx);
                self.my_picture = Some(p.picture.clone()).filter(|u| !u.is_empty());
                let pic = self.my_picture.clone();
                let img = self.ui.image(cx, ids!(me_avatar.pic));
                images::show(cx, &img, pic.as_deref());
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
            Update::Card(card) => self.show_card(cx, card),
            Update::GifLibrary { favorites, collections } => {
                self.gif_favorites = favorites.clone();
                self.gif_collections = collections.clone();
                if let GifView::Collection(id) = &self.gif_view {
                    if !collections.iter().any(|c| c.id == *id) {
                        self.gif_view = GifView::Home;
                    }
                }
                if self.ui.view(cx, ids!(composer_picker)).visible() {
                    self.refresh_picker(cx, false);
                }
            }
            Update::EmojiSets(sets) => {
                self.emoji_sets = sets.clone();
                self.show_status_emoji(cx);
            }
            Update::UploadAuth { id, header, servers } => {
                if let Some(done) = self.uploads.authorized(cx, *id, header.clone(), servers.clone()) {
                    self.upload_done(cx, done);
                }
            }
            Update::Home(h) => {
                self.home_data = h.clone();
                self.ui.view(cx, ids!(home_badge)).set_visible(cx, h.badge > 0);
                let n = if h.badge > 99 { "99+".to_owned() } else { h.badge.to_string() };
                self.ui.label(cx, ids!(home_badge.count)).set_text(cx, &n);
                self.fill_request_bar(cx);
                if self.home {
                    self.fill_dm_sidebar(cx);
                    self.fill_friends(cx);
                }
            }
            Update::DmHeader { person, request } => {
                if self.dm_with.as_deref() != Some(person.pubkey.as_str()) {
                    return;
                }
                self.dm_name = person.name.clone();
                self.ui.label(cx, ids!(channel_hash)).set_text(cx, "@");
                self.ui.label(cx, ids!(channel_name)).set_text(cx, &person.name);
                self.ui.rich_input(cx, ids!(composer)).set_empty_text(cx, format!("Message @{}", person.name));
                self.ui.view(cx, ids!(dm_request)).set_visible(cx, request.is_some());
                self.ui.view(cx, ids!(composer_box)).set_visible(cx, request.is_none());
                if let Some(n) = request {
                    self.ui.label(cx, ids!(req_name)).set_text(cx, &person.name);
                    self.ui.label(cx, ids!(req_avatar.initial)).set_text(cx, &person.initial);
                    let mut a = self.ui.widget(cx, ids!(req_avatar));
                    let c = lists::rgba(person.avatar, 1.0);
                    script_apply_eval!(cx, a, {draw_bg +: {color: #(c)}});
                    self.ui.label(cx, ids!(req_waiting))
                        .set_text(cx, &format!("{n} message{} waiting", if *n == 1 { "" } else { "s" }));
                } else {
                    self.send(backend::Command::MarkDmRead(person.pubkey.clone()));
                }
                self.ui.redraw(cx);
            }
            Update::People(people) => {
                self.found = people.clone();
                if self.friends_tab == 4 {
                    self.fill_friends(cx);
                }
            }
            Update::Theme(name) => {
                self.saved_theme = name.clone();
                self.apply_theme(cx, name);
            }
            Update::SearchResults { query, rows } => {
                let n = rows.len();
                self.ui.label(cx, ids!(search_count)).set_text(
                    cx,
                    &format!("{} result{} for \"{}\"", n, if n == 1 { "" } else { "s" }, query),
                );
                if let Some(mut l) = self.ui.widget(cx, ids!(search_results)).borrow_mut::<lists::ResultList>() {
                    l.rows = rows.clone();
                }
                lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(search_results.list)));
                self.show_search_panel(cx, true);
            }
            Update::ServerSettings(settings) => {
                self.srv = settings.clone();
                if self.ui.view(cx, ids!(srv_settings)).visible() {
                    // Keep unsaved role edits; refresh the rest.
                    let drafts = std::mem::take(&mut self.role_drafts);
                    let sel = self.role_sel;
                    self.fill_srv_pages(cx);
                    if !drafts.is_empty() && roles_differ(&drafts, &self.srv.roles) {
                        self.role_drafts = drafts;
                        self.role_sel = sel.min(self.role_drafts.len().saturating_sub(1));
                        self.show_role(cx);
                    }
                }
            }
            Update::Notice(n) => self.toast(cx, n, Toast::Success),
            Update::Error(e) => {
                self.toast(cx, e, Toast::Error);
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
        let (frequent, collapsed, tab) = picker::load();
        self.picker_frequent = frequent;
        self.picker_collapsed = collapsed;
        self.picker_tab = if tab <= PICKER_EMOJI { tab } else { PICKER_EMOJI };
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
            if self.home {
                self.set_home(cx, false);
            }
            self.send(backend::Command::SelectServer(gid));
        }

        // Links and mentions in message bodies.
        for action in actions {
            let Some(wa) = action.as_widget_action() else { continue };
            match wa.cast::<message_text::MessageTextAction>() {
                message_text::MessageTextAction::Link(url) if url.starts_with("https://") || url.starts_with("http://") => {
                    cx.open_url(&url, OpenUrlInPlace::No);
                }
                message_text::MessageTextAction::FavoriteGif(url) => {
                    self.send(backend::Command::ToggleGifFavorite(Gif { url, preview: String::new() }));
                }
                message_text::MessageTextAction::Mention(who) if who.len() == 64 => {
                    self.card_at = Some(self.last_press + dvec2(0.0, 12.0));
                    self.send(backend::Command::Card(who));
                }
                _ => {}
            }
        }

        // Home
        let tap = |ui: &WidgetRef, cx: &mut Cx, path: &[LiveId]| ui.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled);
        // Picker: open, tabs, search, picks.
        if tap(&self.ui, cx, ids!(emoji_btn)) {
            let open = !self.ui.view(cx, ids!(composer_picker)).visible();
            self.set_composer_picker(cx, open);
        }
        if tap(&self.ui, cx, ids!(p_status_emoji)) {
            self.open_status_picker(cx);
        }
        if tap(&self.ui, cx, ids!(composer_picker.gif_back)) {
            self.gif_view = GifView::Home;
            self.refresh_picker(cx, false);
        }
        if let Some((link, _)) = self.ui.text_input(cx, ids!(composer_picker.gif_link)).returned(actions) {
            let url = link.trim().to_owned();
            if inferno_core::gifs::looks_like_gif(&url) {
                if !self.gif_favorites.iter().any(|g| g.url == url) {
                    self.send(backend::Command::ToggleGifFavorite(Gif { url, preview: String::new() }));
                }
                self.ui.text_input(cx, ids!(composer_picker.gif_link)).set_text(cx, "");
            } else {
                self.toast(cx, "That link isn't a GIF (try a .gif or media.tenor.com link).", Toast::Error);
            }
        }
        if let Some((name, _)) = self.ui.text_input(cx, ids!(composer_picker.collection_name)).returned(actions) {
            if !name.trim().is_empty() {
                self.send(backend::Command::CreateGifCollection(name.trim().to_owned()));
            }
            self.ui.text_input(cx, ids!(composer_picker.collection_name)).set_text(cx, "");
            self.ui.view(cx, ids!(composer_picker.new_collection)).set_visible(cx, false);
        }
        if tap(&self.ui, cx, ids!(status_clear)) {
            self.status_emoji.clear();
            self.show_status_emoji(cx);
            self.close_pickers(cx);
        }
        for (path, tab) in [
            (ids!(composer_picker.tab_gifs), PICKER_GIFS),
            (ids!(composer_picker.tab_stickers), PICKER_STICKERS),
            (ids!(composer_picker.tab_emoji), PICKER_EMOJI),
        ] {
            if tap(&self.ui, cx, path) {
                self.gif_view = GifView::Home;
                self.picker_tab = tab;
                picker::save(&self.picker_frequent, &self.picker_collapsed, self.picker_tab);
                self.refresh_picker(cx, false);
            }
        }
        for status in [false, true] {
            let (panel, items) = Self::picker_paths(status);
            if self.ui.text_input(cx, &[panel[0], id!(search)]).changed(actions).is_some() {
                self.refresh_picker(cx, status);
            }
            let pick = self.ui.widget(cx, items).borrow::<lists::PickerList>().and_then(|l| l.picked(cx, actions));
            if let Some(pick) = pick {
                self.picked(cx, status, pick);
            }
        }

        // Profile editor: pictures, live colours and initial.
        if tap(&self.ui, cx, ids!(ed_avatar)) {
            self.pick_picture(cx, uploads::Purpose::Avatar);
        }
        if tap(&self.ui, cx, ids!(ed_banner)) {
            self.pick_picture(cx, uploads::Purpose::Banner);
        }
        for path in [ids!(p_color), ids!(p_color_2), ids!(p_display), ids!(p_username)] {
            if self.ui.text_input(cx, path).changed(actions).is_some() {
                self.paint_profile_editor(cx);
            }
        }
        for action in actions {
            let Some(fa) = action.downcast_ref::<FileDialogAction>() else { continue };
            let (id, bytes) = match fa {
                FileDialogAction::FileLoaded { id, files } => (*id, files.first().map(|f| f.bytes.to_vec())),
                FileDialogAction::FileSelected { id, paths } => (*id, paths.first().and_then(|p| std::fs::read(p).ok())),
                _ => continue,
            };
            let purpose = match id {
                id if id == live_id!(pick_avatar) => uploads::Purpose::Avatar,
                id if id == live_id!(pick_banner) => uploads::Purpose::Banner,
                id if id == live_id!(pick_srv_icon) => uploads::Purpose::ServerIcon,
                id if id == live_id!(pick_srv_banner) => uploads::Purpose::ServerBanner,
                id if id == live_id!(pick_emoji) => uploads::Purpose::Emoji,
                id if id == live_id!(pick_sticker) => uploads::Purpose::Sticker,
                _ => continue,
            };
            self.custom_file_name = match fa {
                FileDialogAction::FileLoaded { files, .. } => files.first().map(|f| f.name.clone()),
                FileDialogAction::FileSelected { paths, .. } => {
                    paths.first().and_then(|p| std::path::Path::new(p).file_name()).map(|n| n.to_string_lossy().into_owned())
                }
                _ => None,
            };
            match bytes {
                Some(b) => self.picked_file(cx, purpose, &b),
                None => self.picture_note(cx, purpose, "⚠ Couldn't read that file."),
            }
        }
        if let Some(z) = self.ui.slider(cx, ids!(crop_zoom)).slided(actions) {
            if let Some((crop, _, _)) = self.crop.as_mut() {
                crop.set_zoom(z);
            }
            self.layout_crop(cx);
        }
        if tap(&self.ui, cx, ids!(crop_cancel)) {
            self.crop = None;
            self.ui.modal(cx, ids!(crop_dialog)).close(cx);
        }
        if self.ui.button(cx, ids!(crop_apply)).clicked(actions) {
            self.apply_crop(cx);
        }
        if tap(&self.ui, cx, ids!(home_btn)) || tap(&self.ui, cx, ids!(friends_link)) {
            self.set_home(cx, true);
            self.show_friends(cx, self.friends_tab);
            self.send(backend::Command::Home);
        }
        if tap(&self.ui, cx, ids!(dm_add_friend)) {
            self.set_home(cx, true);
            self.show_friends(cx, 4);
            if let Some(mut input) = self.ui.text_input(cx, ids!(find_input)).borrow_mut() {
                input.take_key_focus(cx);
            }
        }
        if tap(&self.ui, cx, ids!(saved_link)) {
            let me = self.my_hex();
            self.open_dm(cx, me);
        }
        for (i, path) in [ids!(tab_online), ids!(tab_all), ids!(tab_pending), ids!(tab_blocked), ids!(tab_search)].into_iter().enumerate() {
            if tap(&self.ui, cx, path) {
                self.show_friends(cx, i);
            }
        }
        let find = self.ui.text_input(cx, ids!(find_input));
        if let Some((q, _)) = find.returned(actions) {
            self.send(backend::Command::FindPeople(q));
        }
        if let Some(q) = find.changed(actions) {
            if q.trim().len() >= 2 {
                self.send(backend::Command::FindPeople(q));
            }
        }
        let pressed = self.ui.widget(cx, ids!(friend_list)).borrow::<lists::FriendList>().and_then(|l| l.pressed(cx, actions));
        if let Some((pk, b)) = pressed {
            use lists::FriendButton as B;
            match b {
                B::Message => self.open_dm(cx, pk),
                B::Add => self.send(backend::Command::AddFriend(pk)),
                B::Accept => self.send(backend::Command::AnswerFriend { pubkey: pk, accept: true }),
                B::Decline => self.send(backend::Command::AnswerFriend { pubkey: pk, accept: false }),
                B::Remove => self.run_menu_action(cx, ctxmenu::Action::RemoveFriend(pk)),
                B::Unblock => self.send(backend::Command::Unblock(pk)),
            }
        }
        let dm_click = self.ui.widget(cx, ids!(dms)).borrow::<lists::DmList>().and_then(|l| l.clicked(cx, actions));
        if let Some(i) = dm_click {
            if let Some(r) = self.home_data.conversations.iter().filter(|c| c.person.pubkey != self.my_hex()).nth(i).cloned() {
                self.open_dm(cx, r.person.pubkey);
            }
        }
        let dm_ctx = self.ui.widget(cx, ids!(dms)).borrow::<lists::DmList>().and_then(|l| l.context(cx, actions));
        if let Some((i, at)) = dm_ctx {
            if let Some(r) = self.home_data.conversations.iter().filter(|c| c.person.pubkey != self.my_hex()).nth(i).cloned() {
                let items = self.dm_menu(&r);
                self.open_menu(cx, items, at);
            }
        }
        if tap(&self.ui, cx, ids!(req_accept)) {
            if let Some(pk) = self.dm_with.clone() {
                self.send(backend::Command::AcceptDm(pk));
            }
        }
        if tap(&self.ui, cx, ids!(req_decline)) {
            if let Some(pk) = self.dm_with.clone() {
                self.send(backend::Command::CloseDm(pk));
                self.show_friends(cx, self.friends_tab);
            }
        }
        // Friend request bar.
        let n = self.home_data.incoming.len();
        if n > 0 {
            let current = self.home_data.incoming[self.bar_index.min(n - 1)].pubkey.clone();
            if tap(&self.ui, cx, ids!(fb_prev)) {
                self.bar_index = (self.bar_index + n - 1) % n;
                self.fill_request_bar(cx);
            }
            if tap(&self.ui, cx, ids!(fb_next)) {
                self.bar_index = (self.bar_index + 1) % n;
                self.fill_request_bar(cx);
            }
            if tap(&self.ui, cx, ids!(fb_accept)) {
                self.send(backend::Command::AnswerFriend { pubkey: current.clone(), accept: true });
            }
            if tap(&self.ui, cx, ids!(fb_decline)) {
                self.send(backend::Command::AnswerFriend { pubkey: current.clone(), accept: false });
            }
            if tap(&self.ui, cx, ids!(fb_ignore)) {
                self.send(backend::Command::IgnoreFriend(current));
            }
        }
        // Card buttons.
        if tap(&self.ui, cx, ids!(card_message)) {
            let pk = self.card.pubkey.clone();
            self.open_dm(cx, pk);
        }
        if tap(&self.ui, cx, ids!(card_friend)) {
            let pk = self.card.pubkey.clone();
            self.close_card(cx);
            match self.card.friend {
                Friend::None => self.send(backend::Command::AddFriend(pk)),
                Friend::Incoming => self.send(backend::Command::AnswerFriend { pubkey: pk, accept: true }),
                Friend::Accepted => self.run_menu_action(cx, ctxmenu::Action::RemoveFriend(pk)),
                Friend::Outgoing => {}
            }
        }
        let member_click = self.ui.widget(cx, ids!(members)).borrow::<lists::MemberList>().and_then(|l| l.clicked_member(cx, actions));
        if let Some((i, at)) = member_click {
            if let Some(backend::MemberRow::Member { pubkey, .. }) = self.members.get(i).cloned() {
                // Rails: to the left of the member list, level with the click.
                let left = self.ui.view(cx, ids!(member_col)).area().rect(cx).pos.x;
                self.card_at = Some(dvec2(left - 288.0 - 8.0, at.y - 24.0));
                self.send(backend::Command::Card(pubkey));
            }
        }
        if self.ui.view(cx, ids!(card_copy)).finger_up(actions).is_some_and(|e| !e.cancelled) {
            cx.copy_to_clipboard(&self.card.npub);
            self.toast(cx, "User ID copied.", Toast::Success);
            self.close_card(cx);
        }
        let member_ctx = self.ui.widget(cx, ids!(members)).borrow::<lists::MemberList>().and_then(|l| l.context(cx, actions));
        if let Some((i, at)) = member_ctx {
            if let Some(backend::MemberRow::Member { pubkey, .. }) = self.members.get(i).cloned() {
                let items = self.member_menu(&pubkey);
                self.open_menu(cx, items, at);
            }
        }
        let sidebar_action = self
            .ui
            .widget(cx, ids!(channels))
            .borrow_mut::<lists::ChannelList>()
            .and_then(|mut c| c.handle_list_actions(cx, actions));
        match sidebar_action {
            Some(lists::ChannelListAction::Select(id)) => self.send(backend::Command::SelectChannel(id)),
            Some(lists::ChannelListAction::CreateIn(cat)) => self.open_channel_page(cx, None, Some(cat)),
            Some(lists::ChannelListAction::Context { row, at }) => {
                let items = self.sidebar_menu(row.as_ref());
                self.open_menu(cx, items, dvec2(at.0, at.1));
            }
            Some(lists::ChannelListAction::Move { id, category, index }) => {
                self.send(backend::Command::MoveChannel { id, category, index })
            }
            None => {}
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

        // Server menu and channel/category dialogs
        if tapped(&self.ui, cx, ids!(server_header)) && !self.channel_forms.is_empty() {
            let open = !self.ui.view(cx, ids!(server_menu)).visible();
            self.set_server_menu(cx, open);
        }
        if tapped(&self.ui, cx, ids!(menu_create_channel)) {
            self.set_server_menu(cx, false);
            self.open_channel_page(cx, None, None);
        }
        if tapped(&self.ui, cx, ids!(menu_create_category)) {
            self.set_server_menu(cx, false);
            self.open_category_page(cx, None);
        }
        if tapped(&self.ui, cx, ids!(menu_invite)) {
            self.set_server_menu(cx, false);
            self.invite_people(cx);
        }
        if tapped(&self.ui, cx, ids!(menu_leave)) {
            self.set_server_menu(cx, false);
            let body = format!("Leave {}?", self.server_name);
            self.confirm(cx, Pending::Leave, "Leave Server", &body, "Leave Server", false);
        }
        // Context menu picks, and the confirm dialog
        for (i, slot) in CTX_SLOTS.iter().enumerate() {
            if tapped(&self.ui, cx, &[id!(ctx_menu), *slot, id!(item)]) {
                if let Some(d) = self.ctx.get(i).cloned() {
                    use ctxmenu::Action as A;
                    let stays_open = matches!(d.action, A::Back | A::RolesFor(_) | A::TimeoutFor(_));
                    if !stays_open {
                        self.close_menu(cx);
                    }
                    self.run_menu_action(cx, d.action);
                }
            }
        }
        if self.ui.button(cx, ids!(confirm_cancel)).clicked(actions) {
            self.pending = None;
            self.ui.modal(cx, ids!(confirm_dialog)).close(cx);
        }
        if self.ui.button(cx, ids!(confirm_ok)).clicked(actions) {
            self.ui.modal(cx, ids!(confirm_dialog)).close(cx);
            if let Some(p) = self.pending.take() {
                self.run_confirmed(cx, p);
            }
        }
        if tapped(&self.ui, cx, ids!(ch_cancel)) || tapped(&self.ui, cx, ids!(cat_cancel)) {
            self.close_pages(cx);
        }
        if self.ui.check_box(cx, ids!(ch_encrypted)).changed(actions).is_some() {
            let on = self.ui.check_box(cx, ids!(ch_encrypted)).active(cx);
            self.ui.view(cx, ids!(ch_roles_box)).set_visible(cx, on);
            self.ui.redraw(cx);
        }
        if let Some(mut picker) = self.ui.widget(cx, ids!(ch_roles)).borrow_mut::<lists::RolePicker>() {
            picker.handle_list_actions(cx, actions);
        }
        if self.ui.button(cx, ids!(ch_save)).clicked(actions) {
            let allowed = self.ui.widget(cx, ids!(ch_roles)).borrow::<lists::RolePicker>().map(|p| p.picked()).unwrap_or_default();
            let existing = self.dialog_channel.as_ref().and_then(|id| self.channel_forms.iter().find(|f| f.id.as_ref() == Some(id)).cloned());
            let form = backend::ChannelForm {
                id: self.dialog_channel.clone(),
                name: self.ui.text_input(cx, ids!(ch_name)).text(),
                topic: self.ui.text_input(cx, ids!(ch_topic)).text(),
                voice: existing.as_ref().map_or_else(|| self.ui.drop_down(cx, ids!(ch_type)).selected_item() == 1, |e| e.voice),
                category: match &existing {
                    Some(e) => e.category.clone(),
                    None => {
                        let i = self.ui.drop_down(cx, ids!(ch_category)).selected_item();
                        i.checked_sub(1).and_then(|i| self.categories.get(i)).map(|c| c.id.clone())
                    }
                },
                encrypted: existing.as_ref().map_or_else(|| self.ui.check_box(cx, ids!(ch_encrypted)).active(cx), |e| e.encrypted),
                allowed_roles: allowed,
                post_only: self.ui.check_box(cx, ids!(ch_post_only)).active(cx),
                nsfw: self.ui.check_box(cx, ids!(ch_nsfw)).active(cx),
            };
            self.send(backend::Command::SaveChannel(form));
            self.close_pages(cx);
        }
        if self.ui.button(cx, ids!(ch_delete)).clicked(actions) {
            if let Some(id) = self.dialog_channel.clone() {
                self.run_menu_action(cx, ctxmenu::Action::DeleteChannel(id));
            }
        }
        if self.ui.button(cx, ids!(cat_save)).clicked(actions) {
            let name = self.ui.text_input(cx, ids!(cat_name)).text();
            match self.dialog_category.clone() {
                Some(id) => self.send(backend::Command::RenameCategory { id, name }),
                None => self.send(backend::Command::CreateCategory(name)),
            }
            self.close_pages(cx);
        }
        // Search
        let search = self.ui.text_input(cx, ids!(search_input));
        let focused = actions
            .find_widget_action(search.widget_uid())
            .is_some_and(|a| matches!(a.cast(), TextInputAction::KeyFocus));
        if focused {
            self.ui.view(cx, ids!(search_suggest)).set_visible(cx, true);
            self.ui.redraw(cx);
        }
        if (search.key_focus_lost(actions) && !self.press_in_suggest) || search.escaped(actions) {
            self.ui.view(cx, ids!(search_suggest)).set_visible(cx, false);
            self.ui.redraw(cx);
        }
        if let Some((text, _)) = search.returned(actions) {
            self.ui.view(cx, ids!(search_suggest)).set_visible(cx, false);
            if !text.trim().is_empty() {
                self.send(backend::Command::Search(text));
            }
        }
        for (path, insert) in [
            (ids!(f_from), "from: "),
            (ids!(f_in), "in: "),
            (ids!(f_has), "has: "),
            (ids!(f_date), "after: "),
            (ids!(f_pinned), "pinned: true "),
        ] {
            if self.ui.view(cx, path).finger_up(actions).is_some_and(|e| !e.cancelled) {
                self.press_in_suggest = false;
                let mut text = search.text();
                if !text.is_empty() && !text.ends_with(' ') {
                    text.push(' ');
                }
                text.push_str(insert);
                set_text_end(cx, &search, &text);
                if let Some(mut input) = search.borrow_mut() {
                    input.take_key_focus(cx);
                }
            }
        }
        if tapped(&self.ui, cx, ids!(close_search)) {
            self.show_search_panel(cx, false);
        }
        let hit = self.ui.widget(cx, ids!(search_results)).borrow::<lists::ResultList>().and_then(|l| l.clicked(cx, actions));
        if let Some(r) = hit {
            let same = self.showing.as_ref().is_some_and(|(_, ch)| *ch == r.channel_id);
            if same {
                if let Some(mut list) = self.ui.widget(cx, ids!(messages)).borrow_mut::<message_list::MessageList>() {
                    list.jump_to(cx, &r.id);
                }
            } else {
                self.pending_jump = Some((r.channel_id.clone(), r.id.clone()));
                self.send(backend::Command::SelectChannel(r.channel_id));
            }
        }

        // Server settings
        if tapped(&self.ui, cx, ids!(menu_server_settings)) {
            self.set_server_menu(cx, false);
            self.open_srv_settings(cx);
        }
        if tapped(&self.ui, cx, ids!(close_srv_settings)) {
            self.ui.view(cx, ids!(srv_settings)).set_visible(cx, false);
        self.ui.view(cx, ids!(role_save_bar)).set_visible(cx, false);
            self.ui.redraw(cx);
        }
        for (i, (nav, _)) in SRV_PAGES.iter().enumerate() {
            if tapped(&self.ui, cx, nav) {
                self.show_srv_page(cx, i);
            }
        }
        if tapped(&self.ui, cx, ids!(snav_delete)) {
            let body = format!("Delete {}? This removes it for every member and cannot be undone.", self.server_name);
            self.confirm(cx, Pending::DeleteServer, "Delete Server", &body, "Delete Server", false);
        }
        if self.ui.button(cx, ids!(so_save)).clicked(actions) {
            let ty = self.ui.drop_down(cx, ids!(so_type)).selected_item().min(SERVER_TYPES.len() - 1);
            let ch = self.ui.drop_down(cx, ids!(so_welcome_ch)).selected_item();
            let o = backend::ServerSettings {
                name: self.ui.text_input(cx, ids!(so_name)).text(),
                about: self.ui.text_input(cx, ids!(so_about)).text(),
                picture: self.srv_icon.clone(),
                banner: self.srv_banner.clone(),
                server_type: SERVER_TYPES[ty].0.to_owned(),
                discoverable: self.ui.check_box(cx, ids!(so_discoverable)).active(cx),
                age_restricted: self.ui.check_box(cx, ids!(so_age)).active(cx),
                welcome_enabled: self.ui.check_box(cx, ids!(so_welcome_on)).active(cx),
                welcome_message: self.ui.text_input(cx, ids!(so_welcome)).text(),
                welcome_channel: ch.checked_sub(1).and_then(|i| self.srv.text_channels.get(i)).map(|c| c.id.clone()),
                ..Default::default()
            };
            self.send(backend::Command::SaveOverview(o));
            self.ui.label(cx, ids!(so_note)).set_text(cx, "");
            self.toast(cx, "Server settings saved.", Toast::Success);
        }
        if self.ui.button(cx, ids!(so_icon_pick)).clicked(actions) {
            self.pick_picture(cx, uploads::Purpose::ServerIcon);
        }
        if self.ui.button(cx, ids!(so_banner_pick)).clicked(actions) {
            self.pick_picture(cx, uploads::Purpose::ServerBanner);
        }
        // Rails' Remove buttons did nothing; these clear it until Save.
        if tap(&self.ui, cx, ids!(so_icon_remove)) {
            self.srv_icon.clear();
            self.paint_server_preview(cx);
            self.ui.label(cx, ids!(so_note)).set_text(cx, "Save Changes to remove it.");
        }
        if tap(&self.ui, cx, ids!(so_banner_remove)) {
            self.srv_banner.clear();
            self.paint_server_preview(cx);
            self.ui.label(cx, ids!(so_note)).set_text(cx, "Save Changes to remove it.");
        }
        let typed = [ids!(so_name), ids!(so_about)].into_iter().any(|p| self.ui.text_input(cx, p).changed(actions).is_some());
        if typed
            || self.ui.drop_down(cx, ids!(so_type)).changed(actions).is_some()
            || self.ui.check_box(cx, ids!(so_age)).changed(actions).is_some()
        {
            self.paint_server_preview(cx);
        }
        if self.ui.button(cx, ids!(inv_generate)).clicked(actions) {
            let e = self.ui.drop_down(cx, ids!(inv_expires)).selected_item();
            let m = self.ui.drop_down(cx, ids!(inv_max)).selected_item();
            self.send(backend::Command::CreateInvite {
                max_uses: INVITE_USES.get(m).copied().unwrap_or(0),
                expires_in: INVITE_EXPIRY.get(e).copied().unwrap_or(0),
            });
        }
        let inv_btn = self.ui.widget(cx, ids!(srv_invites)).borrow::<lists::PeopleList>().and_then(|l| l.pressed(cx, actions));
        match inv_btn {
            Some((code, 0)) => {
                if let Some(i) = self.srv.invites.iter().find(|i| i.code == code) {
                    cx.copy_to_clipboard(&i.link);
                    self.toast(cx, "Invite link copied.", Toast::Success);
                }
            }
            Some((code, _)) => self.confirm(cx, Pending::RevokeInvite(code), "Revoke Invite", "Revoke this invite? Its link stops working.", "Revoke", false),
            None => {}
        }
        let role_act = self.ui.widget(cx, ids!(role_list)).borrow_mut::<lists::RoleList>().and_then(|mut l| l.handle_list_actions(cx, actions));
        match role_act {
            Some(lists::RoleListAction::Select(i)) => {
                self.read_role_editor(cx);
                self.role_sel = i;
                self.show_role(cx);
            }
            Some(lists::RoleListAction::Move { from, to }) => self.move_role(cx, from, to),
            None => {}
        }
        for (i, path) in [ids!(role_tab_display), ids!(role_tab_perms), ids!(role_tab_members)].into_iter().enumerate() {
            if tap(&self.ui, cx, path) {
                self.role_tab = i;
                self.show_role_tab(cx);
            }
        }
        let toggled = self.role_editable()
            && self.ui.widget(cx, ids!(role_perms)).borrow_mut::<lists::PermList>().is_some_and(|mut l| l.handle_list_actions(cx, actions));
        let typed = [ids!(role_name), ids!(role_color)].into_iter().any(|p| self.ui.text_input(cx, p).changed(actions).is_some());
        if toggled || typed {
            self.read_role_editor(cx);
            self.paint_role(cx);
        }
        for (path, hoist) in [(ids!(role_hoist), true), (ids!(role_mention), false)] {
            if tap(&self.ui, cx, path) && self.role_editable() {
                if let Some(r) = self.role_drafts.get_mut(self.role_sel) {
                    if hoist { r.hoist = !r.hoist } else { r.mentionable = !r.mentionable }
                }
                self.paint_role(cx);
            }
        }
        const SWATCHES: [u32; 20] = [
            0x1abc9c, 0x2ecc71, 0x3498db, 0x9b59b6, 0xe91e63, 0xf1c40f, 0xe67e22, 0xe74c3c, 0x95a5a6, 0x607d8b,
            0x11806a, 0x1f8b4c, 0x206694, 0x71368a, 0xad1457, 0xc27c0e, 0xa84300, 0x992d22, 0xffffff, 0x99aab5,
        ];
        let swatch_ids: [&[LiveId]; 20] = [
            ids!(sw0), ids!(sw1), ids!(sw2), ids!(sw3), ids!(sw4), ids!(sw5), ids!(sw6), ids!(sw7), ids!(sw8), ids!(sw9),
            ids!(sw10), ids!(sw11), ids!(sw12), ids!(sw13), ids!(sw14), ids!(sw15), ids!(sw16), ids!(sw17), ids!(sw18), ids!(sw19),
        ];
        for (path, c) in swatch_ids.into_iter().zip(SWATCHES) {
            if tap(&self.ui, cx, path) && self.role_editable() {
                let hex = format!("#{c:06x}");
                self.ui.text_input(cx, ids!(role_color)).set_text(cx, &hex);
                self.read_role_editor(cx);
                self.paint_role(cx);
            }
        }
        if self.ui.text_input(cx, ids!(role_member_search)).changed(actions).is_some() {
            self.fill_role_members(cx);
        }
        let member_toggle = self.ui.widget(cx, ids!(role_members)).borrow::<lists::PeopleList>().and_then(|l| l.pressed(cx, actions));
        if let Some((pk, _)) = member_toggle {
            let role = self.role_drafts.get(self.role_sel).map(|r| r.id.clone());
            let current = self.members.iter().find_map(|m| match m {
                backend::MemberRow::Member { pubkey, roles, .. } if *pubkey == pk => Some(roles.clone()),
                _ => None,
            });
            if let (Some(role), Some(mut roles)) = (role, current) {
                match roles.iter().position(|r| *r == role) {
                    Some(i) => {
                        roles.remove(i);
                    }
                    None => roles.push(role),
                }
                self.send(backend::Command::SetMemberRoles { pubkey: pk, roles });
            }
        }
        if self.ui.button(cx, ids!(role_create)).clicked(actions) && self.perms.manage_roles {
            self.read_role_editor(cx);
            // Rails' new role: "new role", #99aab5, at the top of what we may
            // manage (just under our own highest role).
            let rank = self.srv.my_rank;
            let top = self.role_drafts.iter().filter(|r| !r.everyone && r.position < rank).map(|r| r.position).max().unwrap_or(0);
            if top + 1 >= rank {
                self.toast(cx, "There's no room under your highest role. Move a role down first.", Toast::Error);
            } else {
                let id = inferno_core::server::publish::new_public_id();
                let at = self.role_drafts.iter().position(|r| r.everyone || r.position < rank).unwrap_or(0);
                self.role_drafts.insert(at, backend::RoleForm {
                    id,
                    name: "new role".into(),
                    color: "#99aab5".into(),
                    position: top + 1,
                    perms: backend::DEFAULT_ON.iter().map(|k| k.to_string()).collect(),
                    ..Default::default()
                });
                self.role_sel = at;
                self.role_tab = 0;
                self.show_role(cx);
            }
        }
        if tap(&self.ui, cx, ids!(role_reset)) {
            self.role_drafts = self.srv.roles.clone();
            self.role_sel = self.role_sel.min(self.role_drafts.len().saturating_sub(1));
            self.show_role(cx);
        }
        if tap(&self.ui, cx, ids!(role_save)) {
            self.read_role_editor(cx);
            let is_color = |c: &str| c.len() == 7 && c.starts_with('#') && u32::from_str_radix(&c[1..], 16).is_ok();
            let bad = self.role_drafts.iter().find(|r| !r.everyone && !is_color(&r.color));
            let empty = self.role_drafts.iter().any(|r| !r.everyone && r.name.trim().is_empty());
            match bad {
                Some(r) => {
                    let msg = format!("\"{}\" isn't a #rrggbb color.", r.color);
                    self.toast(cx, &msg, Toast::Error);
                }
                None if empty => self.toast(cx, "Every role needs a name.", Toast::Error),
                None => {
                    self.send(backend::Command::SaveRoles(self.role_drafts.clone()));
                    self.toast(cx, "Roles saved.", Toast::Success);
                }
            }
        }
        if self.ui.button(cx, ids!(role_delete)).clicked(actions) {
            if let Some(r) = self.role_drafts.get(self.role_sel).cloned() {
                let body = format!("Delete the {} role? Members who have it lose it.", r.name);
                self.confirm(cx, Pending::DeleteRole(r.id), "Delete Role", &body, "Delete Role", false);
            }
        }
        if tap(&self.ui, cx, ids!(em_preview)) {
            self.pick_picture(cx, uploads::Purpose::Emoji);
        }
        if tap(&self.ui, cx, ids!(st_preview)) {
            self.pick_picture(cx, uploads::Purpose::Sticker);
        }
        if self.ui.button(cx, ids!(em_submit)).clicked(actions) {
            self.upload_custom(cx, false);
        }
        if self.ui.button(cx, ids!(st_submit)).clicked(actions) {
            self.upload_custom(cx, true);
        }
        let em_del = self.ui.widget(cx, ids!(em_list)).borrow::<lists::CustomList>().and_then(|l| l.deleted(cx, actions));
        if let Some(name) = em_del {
            let body = format!("Delete :{name}:?");
            self.confirm(cx, Pending::RemoveEmoji(name), "Delete Emoji", &body, "Delete", false);
        }
        let st_del = self.ui.widget(cx, ids!(st_list)).borrow::<lists::CustomList>().and_then(|l| l.deleted(cx, actions));
        if let Some(name) = st_del {
            let body = format!("Delete sticker '{name}'?");
            self.confirm(cx, Pending::RemoveSticker(name), "Delete Sticker", &body, "Delete", false);
        }
        let member_act = self.ui.widget(cx, ids!(srv_members)).borrow_mut::<lists::MemberAdminList>().and_then(|mut l| l.handle_list_actions(cx, actions));
        if let Some(act) = member_act {
            use lists::MemberAdminAction as M;
            match act {
                M::Check(_) => {
                    let n = self.selected_members(cx).len();
                    self.paint_member_batch(cx, n);
                }
                M::Roles(pk, at) => {
                    let items = self.roles_menu(&pk, false);
                    self.open_menu(cx, items, at);
                }
                M::Timeout(pk, at) => {
                    let items = self.timeout_menu(&pk, false);
                    self.open_menu(cx, items, at);
                }
                M::RemoveTimeout(pk) => self.send(backend::Command::Timeout { pubkey: pk, secs: 0 }),
                M::Kick(pk) => self.run_menu_action(cx, ctxmenu::Action::Kick(pk)),
                M::Ban(pk) => self.run_menu_action(cx, ctxmenu::Action::Ban(pk)),
            }
        }
        if self.ui.text_input(cx, ids!(mem_search)).changed(actions).is_some() {
            self.fill_people(cx);
        }
        if tap(&self.ui, cx, ids!(mem_select_all)) {
            let selectable: Vec<String> = self.srv.members.iter().filter(|m| !m.owner && !m.me).map(|m| m.pubkey.clone()).collect();
            let n = if let Some(mut l) = self.ui.widget(cx, ids!(srv_members)).borrow_mut::<lists::MemberAdminList>() {
                if l.selected.len() == selectable.len() && !selectable.is_empty() {
                    l.selected.clear();
                } else {
                    l.selected = selectable.into_iter().collect();
                }
                l.selected.len()
            } else {
                0
            };
            lists::redraw_items(cx, &self.ui.portal_list(cx, ids!(srv_members.list)));
            self.paint_member_batch(cx, n);
        }
        if let Some(e) = self.ui.view(cx, ids!(mem_batch_timeout)).finger_up(actions).filter(|e| !e.cancelled) {
            let items = self.batch_timeout_menu();
            self.open_menu(cx, items, e.abs);
        }
        if tap(&self.ui, cx, ids!(mem_batch_kick)) {
            let pks = self.selected_members(cx);
            let body = format!("Kick {} members from {}?", pks.len(), self.server_name);
            self.confirm(cx, Pending::BatchKick(pks), "Kick Members", &body, "Kick", false);
        }
        if tap(&self.ui, cx, ids!(mem_batch_ban)) {
            let pks = self.selected_members(cx);
            let body = format!("Ban {} members from {}?", pks.len(), self.server_name);
            self.confirm(cx, Pending::BatchBan(pks), "Ban Members", &body, "Ban", true);
        }
        let ban_btn = self.ui.widget(cx, ids!(srv_bans)).borrow::<lists::PeopleList>().and_then(|l| l.pressed(cx, actions));
        if let Some((pk, _)) = ban_btn {
            self.send(backend::Command::Unban(pk));
        }

        // Settings overlay
        if tapped(&self.ui, cx, ids!(open_settings)) {
            self.set_settings_open(cx, true);
        }
        if tapped(&self.ui, cx, ids!(close_settings)) {
            self.set_settings_open(cx, false);
        }
        for (path, name) in THEME_TILES {
            if tapped(&self.ui, cx, path) {
                self.apply_theme(cx, name);
                self.mark_theme_tiles(cx);
            }
        }
        if tapped(&self.ui, cx, ids!(theme_save)) {
            let name = theme::current().name.to_owned();
            self.saved_theme = name.clone();
            self.send(backend::Command::SetTheme(name));
            self.toast(cx, "Theme saved.", Toast::Success);
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
                status_emoji: self.status_emoji.clone(),
                color: get(&self.ui, cx, ids!(p_color)),
                color_2: get(&self.ui, cx, ids!(p_color_2)),
                picture: self.draft_picture.clone(),
                banner: self.draft_banner.clone(),
            };
            let is_color = |c: &str| c.len() == 7 && c.starts_with('#') && u32::from_str_radix(&c[1..], 16).is_ok();
            let bad = [&form.color, &form.color_2].into_iter().find(|c| !c.is_empty() && !is_color(c));
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
            self.add_server_tab(cx, false);
            self.ui.modal(cx, ids!(dialog)).open(cx);
            self.discover(cx);
        }
        if tap(&self.ui, cx, ids!(add_close)) {
            self.ui.modal(cx, ids!(dialog)).close(cx);
        }
        if tap(&self.ui, cx, ids!(add_tab_browse)) {
            self.add_server_tab(cx, false);
        }
        if tap(&self.ui, cx, ids!(add_tab_create)) {
            self.add_server_tab(cx, true);
        }
        if tap(&self.ui, cx, ids!(discover_refresh)) {
            self.discover(cx);
        }
        let picked = self.ui.widget(cx, ids!(discover_list)).borrow::<lists::DiscoverList>().and_then(|l| l.clicked(cx, actions));
        if let Some(l) = picked {
            self.ui.modal(cx, ids!(dialog)).close(cx);
            self.set_home(cx, false);
            if l.joined {
                self.send(backend::Command::SelectServer(l.gid));
            } else if l.age_restricted || l.server_type == "adult" {
                let body = format!("{} is age-restricted (18+). By joining, you confirm you are 18 years of age or older.", l.name);
                self.confirm(cx, Pending::JoinPublic(l.gid, l.owner.to_hex()), "Age-restricted server", &body, "I am 18 or older — Join", false);
            } else {
                self.send(backend::Command::JoinPublic { gid: l.gid, owner: l.owner.to_hex() });
                self.toast(cx, &format!("Joining {}…", l.name), Toast::Info);
            }
        }
        if self.ui.view(cx, ids!(profile_btn)).finger_up(actions).is_some_and(|e| !e.cancelled) && !self.npub.is_empty() {
            cx.copy_to_clipboard(&self.npub);
            self.toast(cx, "Your public key was copied.", Toast::Success);
        }
        if self.ui.view(cx, ids!(invite_btn)).finger_up(actions).is_some_and(|e| !e.cancelled) {
            self.invite_people(cx);
        }
        if self.ui.button(cx, ids!(create_server)).clicked(actions) {
            let name = self.ui.text_input(cx, ids!(new_server_name)).text();
            if !name.trim().is_empty() {
                let ty = self.ui.drop_down(cx, ids!(new_server_type)).selected_item().min(SERVER_TYPES.len() - 1);
                self.send(backend::Command::CreateServer { name, server_type: SERVER_TYPES[ty].0.to_owned() });
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

        let composer = self.ui.rich_input(cx, ids!(composer));
        if composer.escaped(actions) {
            self.clear_bars(cx);
        }
        // The bar lights up while the composer has focus.
        let focus = actions.find_widget_action(composer.widget_uid()).map(|a| a.cast::<TextInputAction>());
        match focus {
            Some(TextInputAction::KeyFocus) => self.ui.view(cx, ids!(composer_shell)).animator_play(cx, ids!(focus.on)),
            Some(TextInputAction::KeyFocusLost) => self.ui.view(cx, ids!(composer_shell)).animator_play(cx, ids!(focus.off)),
            _ => {}
        }
        if tapped(&self.ui, cx, ids!(spoiler_btn)) || tapped(&self.ui, cx, ids!(spoiler_bar.close)) {
            self.spoiler = !self.spoiler;
            self.ui.view(cx, ids!(spoiler_bar)).set_visible(cx, self.spoiler);
            self.focus_composer(cx);
        }
        let send_now = tapped(&self.ui, cx, ids!(send_btn)).then(|| composer.text());
        if let Some(text) = composer.returned(actions).map(|(t, _)| t).or(send_now) {
            let text = text.trim();
            if !text.is_empty() {
                match self.editing.take() {
                    Some(id) => self.send(backend::Command::Edit { id, text: text.to_owned() }),
                    None => {
                        let reply_to = self.reply_to.take();
                        let spoiler = std::mem::take(&mut self.spoiler);
                        self.ui.view(cx, ids!(spoiler_bar)).set_visible(cx, false);
                        self.send(backend::Command::Send { text: text.to_owned(), reply_to, spoiler });
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
        rich_input::script_mod(vm);
        message_text::script_mod(vm);
        self::script_mod(vm)
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event) {
        if self.toast_timer.is_event(event).is_some() {
            let now = std::time::Instant::now();
            let before = self.toasts.len();
            self.toasts.retain(|(_, _, until)| *until > now);
            if self.toasts.len() != before {
                self.show_toasts(cx);
            }
            if self.toasts.is_empty() {
                cx.stop_timer(self.toast_timer);
                self.toast_timer = Timer::empty();
            }
        }
        for done in self.uploads.handle_event(cx, event) {
            self.upload_done(cx, done);
        }
        // Dragging the picture in the editor.
        if self.crop.is_some() {
            let area = self.ui.view(cx, ids!(crop_view)).area();
            match event.hits(cx, area) {
                Hit::FingerDown(fe) => self.crop_drag = Some(fe.abs),
                Hit::FingerMove(fe) => {
                    if let (Some(last), Some((crop, _, _))) = (self.crop_drag, self.crop.as_mut()) {
                        crop.drag(fe.abs.x - last.x, fe.abs.y - last.y);
                        self.crop_drag = Some(fe.abs);
                        self.layout_crop(cx);
                    }
                }
                Hit::FingerUp(_) => self.crop_drag = None,
                _ => {}
            }
        }
        if images::handle_event(cx, event) {
            // A picture arrived: rows recorded before it need redrawing.
            let lists: [&[LiveId]; 8] = [
                ids!(rail.list),
                ids!(discover_list.list),
                ids!(members.list),
                ids!(messages.list),
                ids!(dms.list),
                ids!(friend_list.list),
                ids!(composer_picker.items.list),
                ids!(status_picker.items.list),
            ];
            for list in lists {
                lists::redraw_items(cx, &self.ui.portal_list(cx, list));
            }
            if self.ui.view(cx, ids!(srv_settings)).visible() {
                self.paint_server_preview(cx);
            }
            if let Some(card) = self.ui.view(cx, ids!(card_layer)).visible().then(|| self.card.clone()) {
                let img = self.ui.image(cx, ids!(card.ring.avatar.pic));
                images::show(cx, &img, card.picture.as_deref());
                let img = self.ui.image(cx, ids!(card.banner));
                images::show(cx, &img, card.banner.as_deref());
            }
            let pic = self.my_picture.clone();
            let img = self.ui.image(cx, ids!(me_avatar.pic));
            images::show(cx, &img, pic.as_deref());
            if self.ui.view(cx, ids!(page_profile)).visible() {
                self.show_profile_pictures(cx);
            }
            self.ui.redraw(cx);
        }
        // A theme switch reapplies the DSL, which resets styling set at
        // runtime; put it back.
        if let Event::LiveEdit = event {
            if self.ui.view(cx, ids!(settings)).visible() {
                self.show_settings_page(cx, self.settings_page);
            }
            if self.ui.view(cx, ids!(srv_settings)).visible() {
                self.show_srv_page(cx, self.srv_page);
            }
        }
        // Esc closes the settings overlay (spec) and open dropdowns.
        if let Event::KeyDown(k) = event {
            if k.key_code == KeyCode::Escape {
                if self.ui.view(cx, ids!(composer_picker)).visible() || self.ui.view(cx, ids!(status_layer)).visible() {
                    self.close_pickers(cx);
                } else if self.ui.view(cx, ids!(card_layer)).visible() {
                    self.close_card(cx);
                } else if self.ui.view(cx, ids!(ctx_layer)).visible() {
                    self.close_menu(cx);
                } else if self.ui.view(cx, ids!(channel_page)).visible() || self.ui.view(cx, ids!(category_page)).visible() {
                    self.close_pages(cx);
                } else if self.ui.view(cx, ids!(server_menu)).visible() {
                    self.set_server_menu(cx, false);
                } else if self.ui.view(cx, ids!(srv_settings)).visible() {
                    self.ui.view(cx, ids!(srv_settings)).set_visible(cx, false);
        self.ui.view(cx, ids!(role_save_bar)).set_visible(cx, false);
                    self.ui.redraw(cx);
                } else if self.ui.view(cx, ids!(settings)).visible() {
                    self.set_settings_open(cx, false);
                }
            }
        }
        // Right-click on empty sidebar space (rows open their own menus).
        if let Event::MouseDown(m) = event {
            if !m.button.is_primary() {
                let over_row = self
                    .ui
                    .widget(cx, ids!(channels))
                    .borrow::<lists::ChannelList>()
                    .map(|l| (l.contains(cx, m.abs), l.row_at(cx, m.abs)));
                if let Some((true, false)) = over_row {
                    let items = self.sidebar_menu(None);
                    self.open_menu(cx, items, m.abs);
                    return;
                }
            }
        }
        // A press outside an open dropdown or menu closes it.
        if let Event::MouseDown(m) = event {
            self.last_press = m.abs;
            let suggest = self.ui.view(cx, ids!(search_suggest));
            self.press_in_suggest = suggest.visible() && suggest.area().rect(cx).contains(m.abs);
            for (panel, button) in [(ids!(composer_picker), ids!(emoji_btn)), (ids!(status_picker), ids!(p_status_emoji))] {
                let p = self.ui.view(cx, panel);
                let inside = p.area().rect(cx).contains(m.abs) || self.ui.view(cx, button).area().rect(cx).contains(m.abs);
                let shown = p.visible() && (panel[0] != id!(status_picker) || self.ui.view(cx, ids!(status_layer)).visible());
                if shown && !inside {
                    self.close_pickers(cx);
                }
            }
            if self.ui.view(cx, ids!(card_layer)).visible() && !self.ui.view(cx, ids!(card)).area().rect(cx).contains(m.abs) {
                self.close_card(cx);
            }
            if self.ui.view(cx, ids!(ctx_layer)).visible() && !self.ui.view(cx, ids!(ctx_menu)).area().rect(cx).contains(m.abs) {
                self.close_menu(cx);
            }
            let menu = self.ui.view(cx, ids!(server_menu));
            if menu.visible() {
                let inside = |r: Rect| r.contains(m.abs);
                let header = self.ui.view(cx, ids!(server_header)).area().rect(cx);
                if !inside(menu.area().rect(cx)) && !inside(header) {
                    self.set_server_menu(cx, false);
                }
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
