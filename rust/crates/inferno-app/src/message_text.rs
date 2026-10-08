//! Makepad's Markdown widget (rev 44a01c5, MIT/Apache-2.0), forked for
//! message bodies: strikethrough on (and drawn as strikethrough, not
//! underline), and links drawn inline in the link colour, as Rails' message
//! HTML does, instead of as a separate link widget. Keep the rest identical.
#![allow(dead_code, clippy::all)]

use makepad_widgets::{
    image::ImageWidgetRefExt, label::LabelWidgetRefExt, view::ViewWidgetRefExt,
    makepad_derive_widget::*, makepad_draw::*, text_flow::TextFlow, widget::*,
};

use pulldown_cmark::{
    Alignment, CodeBlockKind, Event as MdEvent, HeadingLevel, Options, Parser, Tag, TagEnd,
};

script_mod! {
    use mod.prelude.widgets_internal.*
    use mod.widgets.*

    mod.widgets.MessageTextBase = #(MessageText::register_widget(vm))

    mod.widgets.MessageText = set_type_default() do mod.widgets.MessageTextBase{
        width: Fill height: Fit
        // Restated from TextFlow rather than inherited. These reach TextFlow
        // through a Rust `#[deref]`, not through the prototype chain, so on a
        // reload -- and a theme switch is a reload -- any of them this block
        // does not name is reset to its FIELD TYPE's default instead of to
        // what TextFlow's own block says. The `Layout` default flows Right,
        // which laid every table row side by side: the header took the whole
        // width, each body row was left zero wide, and a table drew its box
        // and its header and nothing else. `heading_margin` and
        // `paragraph_margin` went to zero the same way.
        table_walk: Walk{width: Fill, height: Fit}
        table_layout: Layout{flow: Flow.Down}
        table_row_walk: Walk{width: Fill, height: Fit}
        table_row_layout: Layout{flow: Flow.Right}
        table_cell_layout: Layout{
            flow: Flow.Right{wrap: true}
            padding: Inset{left: 6, right: 6, top: 4, bottom: 4}
        }
        heading_margin: Inset{top: 1.0, bottom: 0.1}
        paragraph_margin: Inset{top: 0.33, bottom: 0.33}

        flow: Flow.Right{wrap: true}
        padding: theme.mspace_1

        font_size: theme.font_size_p
        font_color: theme.color_label_inner

        paragraph_spacing: 16
        pre_code_spacing: 8
        inline_code_padding: theme.mspace_1
        inline_code_margin: theme.mspace_1
        heading_base_scale: 1.8

        draw_text +: {
            color: theme.color_label_inner
        }

        text_style_normal: theme.font_regular{
            font_size: theme.font_size_p
        }

        text_style_italic: theme.font_italic{
            font_size: theme.font_size_p
        }

        text_style_bold: theme.font_bold{
            font_size: theme.font_size_p
        }

        text_style_bold_italic: theme.font_bold_italic{
            font_size: theme.font_size_p
        }

        text_style_fixed: theme.font_code{
            font_size: theme.font_size_p
        }

        code_layout: Layout{
            flow: Flow.Right{wrap: true}
            padding: Inset{left: theme.space_3, right: theme.space_3, top: theme.space_2, bottom: 10}
        }
        code_walk: Walk{width: Fill height: Fit}

        quote_layout: Layout{
            flow: Flow.Right{wrap: true}
            padding: Inset{left: theme.space_3, right: theme.space_3, top: theme.space_2, bottom: theme.space_2}
        }
        quote_walk: Walk{width: Fill height: Fit}

        list_item_layout: Layout{
            flow: Flow.Right{wrap: true}
            padding: theme.mspace_1
        }
        list_item_walk: Walk{
            height: Fit width: Fill
        }

        sep_walk: Walk{
            width: Fill height: 4.
            margin: theme.mspace_v_1
        }

        draw_block +: {
            line_color: theme.color_label_inner
            sep_color: theme.color_shadow
            quote_bg_color: theme.color_bg_highlight
            quote_fg_color: theme.color_label_inner
            code_color: theme.color_bg_highlight
            selection_color: theme.color_selection_focus
            table_header_bg_color: theme.color_bg_highlight
            table_border_color: theme.color_shadow
            space_1: uniform(theme.space_1)
            space_2: uniform(theme.space_2)
        }

        link_color: #x60a5fa
        mention_color: #x60a5fa
        mention_bg: #x60a5fa26
        mention_bg_hover: #x60a5fa4d
        everyone_color: #xfacc15
        everyone_bg: #xeab30826
        everyone_bg_hover: #xeab3084d
    }
}

/// The state of a list at a given nesting level.
struct ListState {
    // Current item number for ordered lists.
    current_number: u64,
    // Start number for ordered lists, None for unordered.
    start_number: Option<u64>,
}

#[derive(Script, ScriptHook, Widget)]
pub struct MessageText {
    #[source]
    source: ScriptObjectRef,
    #[deref]
    pub text_flow: TextFlow,
    #[live]
    body: ArcStringMut,
    /// Links and mentions: Rails' accent-light.
    #[live]
    link_color: Vec4f,
    #[live]
    mention_color: Vec4f,
    #[live]
    mention_bg: Vec4f,
    #[live]
    mention_bg_hover: Vec4f,
    #[live]
    everyone_color: Vec4f,
    #[live]
    everyone_bg: Vec4f,
    #[live]
    everyone_bg_hover: Vec4f,
    /// The link or mention under the pointer (index into `targets`).
    #[rust]
    hovered: Option<usize>,
    /// The link being read: its target and the text inside it, drawn as one
    /// inline widget when it closes.
    #[rust]
    open_link: Option<(String, String)>,
    /// Images and GIFs drawn this pass: (item id, url, name).
    #[rust]
    media: Vec<(LiveId, String, String)>,
    /// Videos, sounds and files drawn this pass: (item id, what a click does).
    #[rust]
    files: Vec<(LiveId, MessageTextAction)>,
    /// Spoilers drawn hidden this pass: (item id, what revealing it records).
    #[rust]
    spoilers: Vec<(LiveId, String)>,
    /// The playing video's player, drawn in its card's place: (player, url, name).
    #[rust]
    playing: Option<(WidgetRef, String, String)>,
    /// The GIF under the pointer: its flame shows (Flutter).
    #[rust]
    hover_media: Option<String>,
    /// Links and mentions drawn this pass: the range of TextFlow's tracked
    /// areas each one covers (one per row it wraps over), and its target.
    #[rust]
    targets: Vec<(std::ops::Range<usize>, String)>,
    #[live]
    paragraph_spacing: f64,
    #[live]
    pre_code_spacing: f64,
    #[live(false)]
    use_code_block_widget: bool,
    #[rust]
    in_code_block: bool,
    #[rust]
    code_block_string: String,
    #[rust]
    in_splash_block: bool,
    #[rust]
    splash_block_string: String,
    #[live(false)]
    use_math_widget: bool,
    #[rust]
    auto_id: u64,
    #[live]
    heading_base_scale: f64,
}

thread_local! {
    /// Spoilers clicked open (`message id|url`), for as long as the app runs.
    static REVEALED: std::cell::RefCell<std::collections::HashSet<String>> = Default::default();
}

/// What revealing the spoiler `url` in the message being drawn records.
fn spoiler_key(url: &str) -> String {
    let k = crate::inline_video::key(url);
    if k.is_empty() { url.to_owned() } else { k }
}

fn revealed(key: &str) -> bool {
    REVEALED.with(|r| r.borrow().contains(key))
}

static FAVORITE_GIFS: std::sync::Mutex<Option<std::collections::HashSet<String>>> = std::sync::Mutex::new(None);

/// The favorites, for lighting the flame on GIFs in messages.
pub fn set_favorite_gifs(urls: impl IntoIterator<Item = String>) {
    *FAVORITE_GIFS.lock().unwrap_or_else(|e| e.into_inner()) = Some(urls.into_iter().collect());
}

fn is_favorite_gif(url: &str) -> bool {
    FAVORITE_GIFS.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|f| f.contains(url))
}

/// Flutter: accent when saved, white at 80% when not.
pub fn flame_color(saved: bool) -> Vec4 {
    if saved { crate::theme::tok("accent", 1.0) } else { vec4(1.0, 1.0, 1.0, 0.8) }
}

impl Widget for MessageText {
    fn is_interactive(&self) -> bool {
        false
    }

    fn handle_event(&mut self, cx: &mut Cx, event: &Event, scope: &mut Scope) {
        let actions = cx.capture_actions(|cx| self.text_flow.handle_event(cx, event, scope));
        // A hidden spoiler's first click shows it (Rails).
        for (id, key) in self.spoilers.clone() {
            let item = self.text_flow.existing_item(id);
            if item.as_view().finger_up(&actions).is_some_and(|e| !e.cancelled && e.was_tap() && e.device.is_primary_hit()) {
                REVEALED.with(|r| r.borrow_mut().insert(key));
                item.redraw(cx);
                self.redraw(cx);
            }
        }
        for (id, url, name) in self.media.clone() {
            let item = self.text_flow.existing_item(id);
            if item.as_view().finger_hover_in(&actions).is_some() && self.hover_media.as_deref() != Some(url.as_str()) {
                self.hover_media = Some(url.clone());
                self.redraw(cx);
            }
            if item.as_view().finger_hover_out(&actions).is_some() && self.hover_media.as_deref() == Some(url.as_str()) {
                self.hover_media = None;
                self.redraw(cx);
            }
            // Left clicks only: a right-click opens the message's menu.
            let tapped = |path: &[LiveId]| {
                item.view(cx, path).finger_up(&actions).is_some_and(|e| !e.cancelled && e.was_tap() && e.device.is_primary_hit())
            };
            if tapped(&[live_id!(fire)]) {
                cx.widget_action(self.widget_uid(), MessageTextAction::FavoriteGif(url.clone()));
            } else if item.as_view().finger_up(&actions).is_some_and(|e| !e.cancelled && e.was_tap() && e.device.is_primary_hit()) {
                cx.widget_action(self.widget_uid(), MessageTextAction::View { url: url.clone(), name: name.clone() });
            }
        }
        for (id, action) in self.files.clone() {
            let item = self.text_flow.existing_item(id);
            // A click, however long it's held (not a drag off it).
            if item.as_view().finger_up(&actions).is_some_and(|e| !e.cancelled && e.is_over && e.device.is_primary_hit()) {
                cx.widget_action(self.widget_uid(), action);
            }
        }
        for (i, (range, target)) in self.targets.clone().into_iter().enumerate() {
            for k in range {
                let Some(area) = self.text_flow.areas_tracker.areas.get(k).copied() else { continue };
                match event.hits(cx, area) {
                    Hit::FingerHoverIn(_) | Hit::FingerHoverOver(_) => {
                        cx.set_cursor(MouseCursor::Hand);
                        if self.hovered != Some(i) {
                            self.hovered = Some(i);
                            self.redraw(cx);
                        }
                    }
                    Hit::FingerHoverOut(_) if self.hovered == Some(i) => {
                        self.hovered = None;
                        self.redraw(cx);
                    }
                    Hit::FingerUp(e) if e.is_over && e.was_tap() && e.device.is_primary_hit() => {
                        let action = match target.strip_prefix(crate::message_format::MENTION_SCHEME) {
                            Some(who) => MessageTextAction::Mention(who.to_owned()),
                            None => MessageTextAction::Link(target.clone()),
                        };
                        cx.widget_action(self.widget_uid(), action);
                    }
                    _ => {}
                }
            }
        }
    }

    fn draw_walk(&mut self, cx: &mut Cx2d, _scope: &mut Scope, walk: Walk) -> DrawStep {
        self.auto_id = 0;
        self.targets.clear();
        self.media.clear();
        self.files.clear();
        self.spoilers.clear();
        self.playing = None;
        self.open_link = None;

        self.begin(cx, walk);
        self.process_markdown_doc(cx);
        self.end(cx);

        DrawStep::done()
    }

    fn text(&self) -> String {
        self.body.as_ref().to_string()
    }

    fn set_text(&mut self, cx: &mut Cx, v: &str) {
        if self.body.as_ref() != v {
            self.body.set(v);
            self.redraw(cx);
        }
    }
}

impl MessageText {
    /// What is at `abs` (a right-click there gets its own menu items, as in
    /// Rails): a link, a picture, a video (its card or its player), a sound
    /// or a file.
    pub fn target_at(&mut self, cx: &mut Cx, abs: DVec2) -> Option<MediaTarget> {
        let inside = |area: Area, cx: &mut Cx| area.is_valid(cx) && area.clipped_rect(cx).contains(abs);
        if let Some((player, url, name)) = self.playing.clone() {
            if inside(player.area(), cx) {
                return Some(MediaTarget::Video { url, name });
            }
        }
        for (id, action) in self.files.clone() {
            if !inside(self.text_flow.existing_item(id).area(), cx) {
                continue;
            }
            return match action {
                MessageTextAction::Play { url, name, audio: false, .. } => Some(MediaTarget::Video { url, name }),
                MessageTextAction::Play { url, name, audio: true, .. } => Some(MediaTarget::Audio { url, name }),
                MessageTextAction::Link(url) => Some(MediaTarget::File(url)),
                _ => None,
            };
        }
        for (id, url, name) in self.media.clone() {
            if inside(self.text_flow.existing_item(id).area(), cx) {
                return Some(MediaTarget::Image { url, name });
            }
        }
        for (range, target) in self.targets.clone() {
            if target.starts_with(crate::message_format::MENTION_SCHEME) {
                continue;
            }
            let hit = range.into_iter().any(|k| {
                self.text_flow.areas_tracker.areas.get(k).copied().is_some_and(|a| a.clipped_rect(cx).contains(abs))
            });
            if hit {
                return Some(MediaTarget::Link(target));
            }
        }
        None
    }

    /// Rails' video cards: moving over one slides its bar in, leaving slides
    /// it out (0.25s). By position: the bar's sliders would take a hover
    /// from the card, which reads as leaving it.
    fn process_markdown_doc(&mut self, cx: &mut Cx2d) {
        let tf = &mut self.text_flow;
        // Track state for nested formatting
        let mut list_stack: Vec<ListState> = Vec::new();
        let mut is_first_block = true;
        // Per-column alignments for the current table, and the current cell's
        // column index within its row. Both are reset when a new table starts.
        let mut table_alignments: Vec<Alignment> = Vec::new();
        let mut table_cell_index: usize = 0;

        let parser = Parser::new_ext(
            self.body.as_ref(),
            Options::ENABLE_TABLES | Options::ENABLE_STRIKETHROUGH,
        );

        for event in parser.into_iter() {
            match event {
                MdEvent::Start(Tag::Heading { level, .. }) => {
                    if !is_first_block {
                        tf.new_line_collapsed_with_spacing(cx, self.paragraph_spacing);
                    }
                    is_first_block = false;
                    let heading_base = self.heading_base_scale;
                    let scale = match level {
                        HeadingLevel::H1 => heading_base,
                        HeadingLevel::H2 => heading_base * 0.75,
                        HeadingLevel::H3 => heading_base * 0.58,
                        HeadingLevel::H4 => heading_base * 0.5,
                        HeadingLevel::H5 => heading_base * 0.42,
                        HeadingLevel::H6 => heading_base * 0.33,
                    };
                    tf.push_size_abs_scale(scale);
                    tf.bold.push();
                }
                MdEvent::End(TagEnd::Heading(_level)) => {
                    tf.bold.pop();
                    tf.font_sizes.pop();
                    tf.new_line_collapsed(cx);
                }
                MdEvent::Start(Tag::Paragraph) => {
                    if !is_first_block {
                        tf.new_line_collapsed_with_spacing(cx, self.paragraph_spacing);
                    }
                    is_first_block = false;
                }
                MdEvent::End(TagEnd::Paragraph) => {
                    // No special handling needed, turtle position is managed by content/following blocks
                }
                MdEvent::Start(Tag::BlockQuote(_)) => {
                    if !is_first_block {
                        tf.new_line_collapsed_with_spacing(cx, self.paragraph_spacing);
                    }
                    is_first_block = false;
                    tf.begin_quote(cx);
                }
                MdEvent::End(TagEnd::BlockQuote(_quote_kind)) => {
                    tf.end_quote(cx);
                }
                MdEvent::Start(Tag::List(first_number)) => {
                    list_stack.push(ListState {
                        start_number: first_number,
                        current_number: first_number.unwrap_or(1),
                    });
                }
                MdEvent::End(TagEnd::List(_is_ordered)) => {
                    list_stack.pop();
                }
                MdEvent::Start(Tag::Item) => {
                    if !is_first_block {
                        tf.new_line_collapsed(cx);
                    }
                    is_first_block = false;
                    let marker = if let Some(state) = list_stack.last_mut() {
                        if state.start_number.is_some() {
                            // Ordered list - use and increment the counter
                            let num = state.current_number;
                            state.current_number += 1;
                            format!("{}.", num)
                        } else {
                            // Unordered list - use bullet
                            "•".to_string()
                        }
                    } else {
                        "•".to_string()
                    };
                    tf.begin_list_item(cx, &marker, 2.5);
                }
                MdEvent::End(TagEnd::Item) => {
                    tf.end_list_item(cx);
                }
                MdEvent::Start(Tag::Emphasis) => {
                    tf.italic.push();
                }
                MdEvent::End(TagEnd::Emphasis) => {
                    tf.italic.pop();
                }
                MdEvent::Start(Tag::Strong) => {
                    tf.bold.push();
                }
                MdEvent::End(TagEnd::Strong) => {
                    tf.bold.pop();
                }
                MdEvent::Start(Tag::Strikethrough) => {
                    tf.strikethrough.push();
                }
                MdEvent::End(TagEnd::Strikethrough) => {
                    tf.strikethrough.pop();
                }
                MdEvent::Start(Tag::Link { dest_url, .. }) => {
                    self.open_link = Some((dest_url.to_string(), String::new()));
                }
                MdEvent::End(TagEnd::Link) => {
                    // Rails: links accent-light, underlined on hover; mentions
                    // an accent/.15 pill in accent (warning colours for
                    // @everyone and @here, the role's colour for roles),
                    // accent/.3 and underlined on hover. Drawn as text runs so
                    // they sit on the baseline; their rects are tracked for
                    // hover and clicks.
                    let Some((target, text)) = self.open_link.take() else { continue };
                    // Custom emoji: inline, Rails' 1.375em (3.5rem alone).
                    let emoji_url = target
                        .strip_prefix(crate::message_format::BIG_EMOJI_SCHEME)
                        .map(|u| (u, true))
                        .or_else(|| target.strip_prefix(crate::message_format::EMOJI_SCHEME).map(|u| (u, false)));
                    if let Some((url, big)) = emoji_url {
                        self.auto_id += 1;
                        let id = LiveId(0x454d_4f4a_0000 + self.auto_id);
                        let item = tf.item(cx, id, if big { live_id!(emoji_big) } else { live_id!(emoji) });
                        let img = item.image(cx, ids!(img));
                        crate::images::show(cx, &img, Some(url));
                        item.draw_all_unscoped(cx);
                        continue;
                    }
                    use crate::message_format::{split_file_target, AUDIO_SCHEME, FILE_SCHEME, IMAGE_SCHEME, SPOILER_SCHEME, VIDEO_SCHEME};
                    let (target, spoiler) = match target.strip_prefix(SPOILER_SCHEME) {
                        Some(rest) => (rest.to_owned(), true),
                        None => (target, false),
                    };
                    // A spoiler not yet clicked open: drawn hidden.
                    let hidden = |url: &str| spoiler.then(|| spoiler_key(url)).filter(|k| !revealed(k));
                    if let Some(rest) = target.strip_prefix(VIDEO_SCHEME) {
                        let (dim, url) = split_file_target(rest);
                        let dims = dim
                            .split_once('x')
                            .and_then(|(w, h)| Some((w.parse::<f64>().ok()?, h.parse::<f64>().ok()?)))
                            .filter(|(w, h)| *w > 0.0 && *h > 0.0)
                            .or_else(|| crate::inline_video::dims_of(url));
                        let (w, h) = crate::inline_video::card_size(dims);
                        let key = crate::inline_video::key(url);
                        let hide = hidden(url);
                        tf.new_line_collapsed(cx);
                        // Playing: the player in the card's place (Rails plays
                        // it in the message).
                        if let Some(player) = crate::inline_video::player_for(&key) {
                            let walk = Walk { margin: Inset { top: 4.0, bottom: 4.0, left: 0.0, right: 0.0 }, ..Walk::fixed(w, h) };
                            while player.draw_walk(cx, &mut Scope::empty(), walk).is_step() {}
                            self.playing = Some((player, url.to_owned(), text.clone()));
                            tf.new_line_collapsed(cx);
                            continue;
                        }
                        self.auto_id += 1;
                        let id = LiveId(0x5649_4445_0000 + self.auto_id);
                        let mut item = tf.item(cx, id, live_id!(video));
                        script_apply_eval!(cx, item, {width: #(w) height: #(h)});
                        // Hidden: no frame, no play button, Rails' label.
                        item.widget(cx, ids!(poster)).set_visible(cx, hide.is_none());
                        item.view(cx, ids!(big)).set_visible(cx, hide.is_none());
                        item.view(cx, ids!(hidden)).set_visible(cx, hide.is_some());
                        if let Some(k) = hide {
                            item.draw_all_unscoped(cx);
                            tf.new_line_collapsed(cx);
                            self.spoilers.push((id, k));
                            continue;
                        }
                        if let Some(mut poster) = item.widget(cx, ids!(poster)).borrow_mut::<crate::inline_video::PosterSlot>() {
                            poster.url = url.to_owned();
                        }
                        item.draw_all_unscoped(cx);
                        tf.new_line_collapsed(cx);
                        self.files.push((id, MessageTextAction::Play { url: url.to_owned(), name: text, audio: false, dims, key }));
                        continue;
                    }
                    let attach = target.strip_prefix(FILE_SCHEME).map(|r| (r, false)).or_else(|| target.strip_prefix(AUDIO_SCHEME).map(|r| (r, true)));
                    if let Some((rest, audio)) = attach {
                        let (size, url) = split_file_target(rest);
                        self.auto_id += 1;
                        let id = LiveId(0x4649_4c45_0000 + self.auto_id);
                        tf.new_line_collapsed(cx);
                        let item = tf.item(cx, id, if audio { live_id!(audio) } else { live_id!(attach) });
                        let hide = hidden(url);
                        let size = match hide {
                            // Rails' spoiler card: what it is stays hidden.
                            Some(_) => Some("Click to reveal".to_owned()),
                            None => size.parse::<u64>().ok().map(inferno_core::media::human_size),
                        };
                        item.label(cx, ids!(info.name)).set_text(cx, if hide.is_some() { "Spoiler" } else { &text });
                        let size_label = item.label(cx, ids!(info.size));
                        size_label.set_visible(cx, size.is_some());
                        size_label.set_text(cx, size.as_deref().unwrap_or(""));
                        if audio {
                            item.view(cx, ids!(play)).set_visible(cx, hide.is_none());
                        }
                        item.draw_all_unscoped(cx);
                        tf.new_line_collapsed(cx);
                        if let Some(k) = hide {
                            self.spoilers.push((id, k));
                            continue;
                        }
                        let action = if audio {
                            MessageTextAction::Play { url: url.to_owned(), name: text, audio: true, dims: None, key: String::new() }
                        } else {
                            MessageTextAction::Link(url.to_owned())
                        };
                        self.files.push((id, action));
                        continue;
                    }
                    let (target, forced) = match target.strip_prefix(IMAGE_SCHEME) {
                        Some(rest) => (split_file_target(rest).1.to_owned(), true),
                        None => (target, false),
                    };
                    // Rails' unfurl_images: an image link becomes the image
                    // (max 384×288, rounded), on its own line.
                    if forced || crate::message_format::is_media(&target) {
                        self.auto_id += 1;
                        let id = LiveId(0x4d45_4449_0000 + self.auto_id);
                        tf.new_line_collapsed(cx);
                        let item = tf.item(cx, id, live_id!(media));
                        let img = item.image(cx, ids!(img));
                        crate::images::show(cx, &img, Some(&target));
                        let hide = hidden(&target);
                        let mut blur_img = img.clone();
                        let blur = if hide.is_some() { 1.0 } else { 0.0 };
                        script_apply_eval!(cx, blur_img, {draw_bg +: {blur: #(blur)}});
                        item.view(cx, ids!(hidden)).set_visible(cx, hide.is_some());
                        if let Some(k) = hide {
                            item.view(cx, ids!(fire)).set_visible(cx, false);
                            item.draw_all_unscoped(cx);
                            tf.new_line_collapsed(cx);
                            self.spoilers.push((id, k));
                            continue;
                        }
                        // Flutter's save button: the Inferno flame on hover,
                        // in the accent once it's a favorite.
                        let gif = inferno_core::gifs::looks_like_gif(&target);
                        let hovered = self.hover_media.as_deref() == Some(target.as_str());
                        item.view(cx, ids!(fire)).set_visible(cx, gif && hovered);
                        if gif && hovered {
                            let mut icon = item.widget(cx, ids!(fire.icon));
                            let c = flame_color(is_favorite_gif(&target));
                            script_apply_eval!(cx, icon, {draw_icon +: {color: #(c)}});
                        }
                        item.draw_all_unscoped(cx);
                        tf.new_line_collapsed(cx);
                        let name = if forced { text } else { crate::message_format::file_name(None, &target) };
                        self.media.push((id, target, name));
                        continue;
                    }
                    let index = self.targets.len();
                    let hovered = self.hovered == Some(index);
                    let who = target.strip_prefix(crate::message_format::MENTION_SCHEME);
                    let saved_bg = tf.draw_block.code_color;
                    let color = match who {
                        Some("everyone") => {
                            tf.draw_block.code_color = if hovered { self.everyone_bg_hover } else { self.everyone_bg };
                            self.everyone_color
                        }
                        Some(w) => {
                            tf.draw_block.code_color = if hovered { self.mention_bg_hover } else { self.mention_bg };
                            w.strip_prefix("role:")
                                .and_then(|hex| u32::from_str_radix(hex, 16).ok())
                                .map(|c| {
                                    vec4(
                                        ((c >> 16) & 0xff) as f32 / 255.0,
                                        ((c >> 8) & 0xff) as f32 / 255.0,
                                        (c & 0xff) as f32 / 255.0,
                                        1.0,
                                    )
                                })
                                .unwrap_or(self.mention_color)
                        }
                        None => self.link_color,
                    };
                    tf.areas_tracker.push_tracker();
                    tf.font_colors.push(color);
                    if who.is_some() {
                        tf.inline_code.push();
                        tf.bold.push();
                    }
                    if hovered {
                        tf.underline.push();
                    }
                    tf.draw_text(cx, &text);
                    if hovered {
                        tf.underline.pop();
                    }
                    if who.is_some() {
                        tf.bold.pop();
                        tf.inline_code.pop();
                    }
                    tf.font_colors.pop();
                    let (a, b) = tf.areas_tracker.pop_tracker();
                    tf.draw_block.code_color = saved_bg;
                    self.targets.push((a..b, target));
                }
                MdEvent::Start(Tag::Image {
                    dest_url, title, ..
                }) => {
                    tf.draw_text(cx, "Image[name:");
                    tf.draw_text(cx, &title);
                    tf.draw_text(cx, ", url:");
                    tf.draw_text(cx, &dest_url);
                    tf.draw_text(cx, "]");
                }
                MdEvent::Start(Tag::CodeBlock(kind)) => {
                    if !is_first_block {
                        tf.new_line_collapsed_with_spacing(cx, self.pre_code_spacing);
                    }
                    is_first_block = false;
                    // Check if this is a runsplash block
                    let is_runsplash = matches!(&kind, CodeBlockKind::Fenced(lang) if lang.as_ref() == "runsplash");
                    if is_runsplash {
                        self.in_splash_block = true;
                        self.splash_block_string.clear();
                    } else if self.use_code_block_widget {
                        self.in_code_block = true;
                        self.code_block_string.clear();
                    } else {
                        tf.push_size_rel_scale(tf.fixed_font_size_scale);
                        tf.fixed.push();
                        tf.begin_code(cx);
                    }
                }
                MdEvent::End(TagEnd::CodeBlock) => {
                    if self.in_splash_block {
                        self.in_splash_block = false;
                        let entry_id = tf.new_counted_id();
                        let sbs = &self.splash_block_string;

                        // Draw the splash block using the $splash_block template
                        tf.item_with(cx, entry_id, id!(splash_block), |cx, item, _tf| {
                            //let tree = item.widget_tree();
                            //cx.with_vm(|vm| {
                            //    log!("$splash_block widget tree:\n{}", tree.display(vm.heap()));
                            //});
                            item.widget(cx, ids!(splash_view)).set_text(cx, sbs);
                            item.draw_all_unscoped(cx);
                        });
                    } else if self.in_code_block {
                        self.in_code_block = false;
                        let entry_id = tf.new_counted_id();
                        let cbs = &self.code_block_string;

                        // Draw the code block and capture the CodeView widget ref
                        let mut code_view_ref = WidgetRef::empty();
                        tf.item_with(cx, entry_id, id!(code_block), |cx, item, _tf| {
                            item.widget(cx, ids!(code_view)).set_text(cx, cbs);
                            item.draw_all_unscoped(cx);
                            code_view_ref = item.widget(cx, ids!(code_view));
                        });

                        // Register the code view widget for cross-child selection
                        // (its area will be queried at event time, not draw time)
                        tf.push_widget_text_for_selection(code_view_ref, &self.code_block_string);
                    } else {
                        tf.font_sizes.pop();
                        tf.fixed.pop();
                        tf.end_code(cx);
                    }
                }
                // Inline code
                MdEvent::Code(text) => {
                    tf.push_size_rel_scale(tf.fixed_font_size_scale);
                    tf.fixed.push();
                    tf.inline_code.push();
                    tf.draw_text(cx, &text);
                    tf.font_sizes.pop();
                    tf.fixed.pop();
                    tf.inline_code.pop();
                }
                // Inline math ($...$)
                MdEvent::InlineMath(text) => {
                    if self.use_math_widget {
                        let entry_id = tf.new_counted_id();
                        tf.item_with(cx, entry_id, live_id!(inline_math), |cx, item, _tf| {
                            item.set_text(cx, &text);
                            item.draw_all_unscoped(cx);
                        });
                    } else {
                        // Fallback: render as inline code style
                        tf.push_size_rel_scale(tf.fixed_font_size_scale);
                        tf.fixed.push();
                        tf.inline_code.push();
                        tf.draw_text(cx, &text);
                        tf.font_sizes.pop();
                        tf.fixed.pop();
                        tf.inline_code.pop();
                    }
                }
                // Display math ($$...$$)
                MdEvent::DisplayMath(text) => {
                    if !is_first_block {
                        tf.new_line_collapsed_with_spacing(cx, self.paragraph_spacing);
                    }
                    is_first_block = false;

                    if self.use_math_widget {
                        let entry_id = tf.new_counted_id();
                        tf.item_with(cx, entry_id, live_id!(display_math), |cx, item, _tf| {
                            item.set_text(cx, &text);
                            item.draw_all_unscoped(cx);
                        });
                    } else {
                        // Fallback: render as code block style
                        tf.begin_code(cx);
                        tf.fixed.push();
                        tf.draw_text(cx, &text);
                        tf.fixed.pop();
                        tf.end_code(cx);
                    }
                }
                MdEvent::Text(text) if self.open_link.is_some() => {
                    if let Some((_, t)) = self.open_link.as_mut() {
                        t.push_str(&text);
                    }
                }
                MdEvent::Text(text) => {
                    if self.in_splash_block {
                        self.splash_block_string.push_str(&text);
                    } else if self.in_code_block {
                        self.code_block_string.push_str(&text);
                    } else {
                        tf.draw_text(cx, &text.trim_end_matches("\n"));
                    }
                }
                MdEvent::SoftBreak => {
                    if self.in_splash_block {
                        self.splash_block_string.push('\n');
                    } else if self.in_code_block {
                        self.code_block_string.push('\n');
                    } else {
                        tf.draw_text(cx, " ");
                    }
                }
                MdEvent::HardBreak => {
                    if self.in_splash_block {
                        self.splash_block_string.push('\n');
                    } else if self.in_code_block {
                        self.code_block_string.push('\n');
                    } else {
                        tf.new_line_collapsed(cx);
                    }
                }
                MdEvent::Rule => {
                    if !is_first_block {
                        tf.new_line_collapsed_with_spacing(cx, self.paragraph_spacing);
                    }
                    is_first_block = false;
                    tf.sep(cx);
                    tf.new_line_collapsed_with_spacing(cx, self.paragraph_spacing);
                }
                MdEvent::TaskListMarker(_) => {
                    // TODO: Implement task list markers
                }
                MdEvent::Start(Tag::Table(alignments)) => {
                    if !is_first_block {
                        tf.new_line_collapsed_with_spacing(cx, self.paragraph_spacing);
                    }
                    is_first_block = false;
                    tf.begin_table(cx, alignments.len());
                    table_alignments = alignments;
                    table_cell_index = 0;
                }
                MdEvent::End(TagEnd::Table) => {
                    tf.end_table(cx);
                    tf.new_line_collapsed_with_spacing(cx, self.paragraph_spacing);
                    table_alignments.clear();
                    table_cell_index = 0;
                }
                MdEvent::Start(Tag::TableHead) => {
                    tf.begin_table_header_row(cx);
                    table_cell_index = 0;
                }
                MdEvent::End(TagEnd::TableHead) => {
                    tf.end_table_row(cx);
                    tf.in_table_header = false;
                }
                MdEvent::Start(Tag::TableRow) => {
                    tf.begin_table_row(cx);
                    table_cell_index = 0;
                }
                MdEvent::End(TagEnd::TableRow) => {
                    tf.end_table_row(cx);
                }
                MdEvent::Start(Tag::TableCell) => {
                    let align_x = table_alignments
                        .get(table_cell_index)
                        .map(alignment_to_x)
                        .unwrap_or(0.0);
                    tf.begin_table_cell(cx, align_x);
                    if tf.in_table_header {
                        tf.bold.push();
                    }
                }
                MdEvent::End(TagEnd::TableCell) => {
                    if tf.in_table_header {
                        tf.bold.pop();
                    }
                    tf.end_table_cell(cx);
                    table_cell_index += 1;
                }
                MdEvent::InlineHtml(text) => {
                    // Support a handful of inline HTML tags that have no
                    // CommonMark equivalent. Anything not matched is ignored,
                    // matching the pre-existing behavior.
                    match text.trim().to_ascii_lowercase().as_str() {
                        "<sub>" => {
                            tf.push_size_rel_scale(0.7);
                            tf.y_shift_scales.push(0.55);
                        }
                        "</sub>" => {
                            tf.font_sizes.pop();
                            tf.y_shift_scales.pop();
                        }
                        "<sup>" => {
                            tf.push_size_rel_scale(0.7);
                            tf.y_shift_scales.push(-0.2);
                        }
                        "</sup>" => {
                            tf.font_sizes.pop();
                            tf.y_shift_scales.pop();
                        }
                        _ => {}
                    }
                }
                _ => {} // Unimplemented or unnecessary events
            }
        }
    }
}

/// Maps pulldown_cmark table-column alignment to `Layout::align.x`.
fn alignment_to_x(alignment: &Alignment) -> f64 {
    match alignment {
        Alignment::None | Alignment::Left => 0.0,
        Alignment::Center => 0.5,
        Alignment::Right => 1.0,
    }
}

impl MessageTextRef {
    pub fn set_text(&mut self, cx: &mut Cx, v: &str) {
        let Some(mut inner) = self.borrow_mut() else {
            return;
        };
        inner.set_text(cx, v)
    }

    /// Start streaming text animation with fade-in effect.
    pub fn start_streaming_animation(&self) {
        if let Some(mut inner) = self.borrow_mut() {
            inner.text_flow.start_streaming_animation();
        }
    }

    /// Reset and start streaming animation (for reused widgets).
    pub fn reset_streaming_animation(&self) {
        if let Some(mut inner) = self.borrow_mut() {
            inner.text_flow.reset_streaming_animation();
        }
    }

    /// Stop streaming animation (fade will complete naturally).
    pub fn stop_streaming_animation(&self) {
        if let Some(mut inner) = self.borrow_mut() {
            inner.text_flow.stop_streaming_animation();
        }
    }

    /// Check if streaming animation is completely done.
    pub fn is_streaming_animation_done(&self) -> bool {
        if let Some(inner) = self.borrow() {
            inner.text_flow.is_streaming_animation_done()
        } else {
            true
        }
    }

    /// Reset all streaming animations (text fade).
    pub fn reset_all_streaming_animations(&self) {
        if let Some(mut inner) = self.borrow_mut() {
            inner.text_flow.reset_all_streaming_animations();
        }
    }
}


/// What a right-click in a message body landed on.
#[derive(Clone, Debug, PartialEq)]
pub enum MediaTarget {
    Link(String),
    Image { url: String, name: String },
    Video { url: String, name: String },
    Audio { url: String, name: String },
    File(String),
}

/// What a click in a message body asks for.
#[derive(Clone, Debug, Default)]
pub enum MessageTextAction {
    #[default]
    None,
    /// An http(s) link to open.
    Link(String),
    /// A mention: a member's hex pubkey, `everyone`, or `role:<rrggbb>`.
    Mention(String),
    /// The 🔥 on a GIF in a message.
    FavoriteGif(String),
    /// An image to open in the viewer.
    View { url: String, name: String },
    /// A video or sound to play; `key` places a video's player in its
    /// message (empty outside the message list).
    Play { url: String, name: String, audio: bool, dims: Option<(f64, f64)>, key: String },
}
