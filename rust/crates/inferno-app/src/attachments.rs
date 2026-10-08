//! Files for the next message (Rails' attach button and file preview).
//! Each goes up to Blossom as soon as it's picked; Send waits for any
//! still on their way, then their URLs follow the text with an imeta tag
//! each.
//!
//! A link that expires (a Discord attachment's) is saved the same way when
//! the message is sent: downloaded, put up on Blossom, and sent as a file
//! in its place, so it keeps working for everyone.

use inferno_core::media::{human_size, mime_for, FileMeta};
use makepad_widgets::*;

use crate::rich_input::RichInputWidgetRefExt;
use crate::{backend, uploads, App, Toast};

/// Rails' chips: as many as fit; we keep ten slots.
pub const MAX: usize = 10;
/// What a Blossom server is likely to take.
const MAX_BYTES: usize = 100 * 1024 * 1024;
const SLOTS: [&[LiveId]; MAX] = [ids!(a0), ids!(a1), ids!(a2), ids!(a3), ids!(a4), ids!(a5), ids!(a6), ids!(a7), ids!(a8), ids!(a9)];
const PICK: LiveId = live_id!(pick_attach);

/// A message waiting on its expiring links to download.
pub struct Preserving {
    text: String,
    reply_to: Option<String>,
    spoiler: bool,
    /// request → link
    waiting: Vec<(LiveId, String)>,
    /// The links now attached as files: they leave the text.
    saved: Vec<String>,
}

/// The links in `text` that will stop working (media_cache::expires).
pub fn expiring_links(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for w in text.split_whitespace() {
        let w = w.trim_start_matches(['<', '(']).trim_end_matches(['>', ')', '.', ',', '!', '?', ';']);
        if crate::media_cache::expires(w) && !out.iter().any(|o| o == w) {
            out.push(w.to_owned());
        }
    }
    out
}

/// The file name in a link: its last part, `%20` and the like decoded.
fn link_file_name(url: &str) -> String {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    let raw = path.trim_end_matches('/').rsplit('/').next().filter(|n| !n.is_empty()).unwrap_or("file");
    let mut out = Vec::with_capacity(raw.len());
    let b = raw.as_bytes();
    let mut i = 0;
    while i < b.len() {
        let hex = |c: u8| (c as char).to_digit(16);
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push((h * 16 + l) as u8);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

pub struct Attachment {
    upload: u64,
    name: String,
    mime: &'static str,
    bytes: Vec<u8>,
    url: Option<String>,
    failed: bool,
    /// The chip's picture is decoded (once).
    shown: bool,
    /// Sent hidden until clicked (Flutter's per-file spoiler).
    spoiler: bool,
}

impl Attachment {
    fn meta(&self) -> Option<FileMeta> {
        Some(FileMeta {
            url: self.url.clone()?,
            mime: self.mime.to_owned(),
            name: self.name.clone(),
            size: Some(self.bytes.len() as u64),
            dim: None,
            spoiler: self.spoiler,
        })
    }
}

impl App {
    pub(crate) fn pick_attachments(&mut self, cx: &mut Cx) {
        // UI tests can't drive the system dialog: INFERNO_TEST_PICK=<file>[,<file>…].
        if let Ok(paths) = std::env::var("INFERNO_TEST_PICK") {
            for path in paths.split(',') {
                match std::fs::read(path) {
                    Ok(bytes) => {
                        let name = std::path::Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                        self.add_attachment(cx, name, bytes);
                    }
                    Err(e) => self.toast(cx, &format!("{path}: {e}"), Toast::Error),
                }
            }
            return;
        }
        cx.open_select_file_dialog(FileDialog::new().set_id(PICK).set_title("Attach files".into()).set_multiple(true).want_bytes(true));
    }

    pub(crate) fn add_attachment(&mut self, cx: &mut Cx, name: String, bytes: Vec<u8>) {
        if self.attachments.len() >= MAX {
            self.toast(cx, &format!("Up to {MAX} files at a time"), Toast::Error);
            return;
        }
        if bytes.len() > MAX_BYTES {
            self.toast(cx, &format!("{name} is too large (over 100 MB)"), Toast::Error);
            return;
        }
        let mime = mime_for(&name);
        let (upload, sha256) = self.uploads.start(uploads::Purpose::Attachment, bytes.clone(), mime);
        self.send(backend::Command::UploadAuth { id: upload, sha256 });
        self.attachments.push(Attachment { upload, name, mime, bytes, url: None, failed: false, shown: false, spoiler: false });
        self.show_attachments(cx);
    }

    pub(crate) fn attachment_uploaded(&mut self, cx: &mut Cx, id: u64, result: Result<String, String>) {
        let Some(a) = self.attachments.iter_mut().find(|a| a.upload == id) else { return };
        match result {
            Ok(url) => {
                // Already have the picture: the sent message needn't fetch it.
                if a.mime.starts_with("image/") {
                    let _ = load_image_from_data_async(cx, std::path::Path::new(&url), std::sync::Arc::new(a.bytes.clone()));
                }
                a.url = Some(url);
            }
            Err(e) => {
                a.failed = true;
                let name = a.name.clone();
                self.toast(cx, &format!("Couldn't upload {name}: {e}"), Toast::Error);
                // A waiting message stays in the composer to retry.
                if let Some((text, reply_to, spoiler)) = self.queued_send.take() {
                    self.reply_to = reply_to;
                    self.spoiler = spoiler;
                    self.ui.view(cx, ids!(spoiler_bar)).set_visible(cx, spoiler);
                    self.ui.rich_input(cx, ids!(composer)).set_text(cx, &text);
                }
            }
        }
        self.show_attachments(cx);
        self.flush_queued_send(cx);
    }

    fn show_attachments(&mut self, cx: &mut Cx) {
        self.ui.view(cx, ids!(attach_bar)).set_visible(cx, !self.attachments.is_empty());
        for (i, slot) in SLOTS.iter().enumerate() {
            let chip = self.ui.view(cx, slot);
            let Some(a) = self.attachments.get_mut(i) else {
                chip.set_visible(cx, false);
                continue;
            };
            chip.set_visible(cx, true);
            let thumb = chip.image(cx, ids!(thumb));
            let picture = a.mime.starts_with("image/");
            if picture && !a.shown {
                a.shown = thumb.load_image_from_data(cx, &a.bytes).is_ok();
            }
            let shown = picture && a.shown;
            thumb.set_visible(cx, shown);
            chip.view(cx, ids!(info)).set_visible(cx, !shown);
            let kind = if a.mime.starts_with("video/") {
                live_id!(i_video)
            } else if a.mime.starts_with("audio/") {
                live_id!(i_audio)
            } else {
                live_id!(i_file)
            };
            for icon in [live_id!(i_file), live_id!(i_video), live_id!(i_audio)] {
                chip.view(cx, &[icon]).set_visible(cx, icon == kind);
            }
            chip.label(cx, ids!(name)).set_text(cx, &a.name);
            chip.label(cx, ids!(size)).set_text(cx, &human_size(a.bytes.len() as u64));
            let state = if a.failed {
                "Failed\nclick to retry"
            } else if a.url.is_none() {
                "Uploading…"
            } else {
                ""
            };
            chip.view(cx, ids!(veil)).set_visible(cx, !state.is_empty());
            chip.label(cx, ids!(state)).set_text(cx, state);
            // A spoiler: the picture blurred under Rails' label, an accent
            // edge, and its eye lit (Flutter).
            let mut thumb = thumb;
            let blur = if a.spoiler { 1.0 } else { 0.0 };
            script_apply_eval!(cx, thumb, {draw_bg +: {blur: #(blur)}});
            chip.view(cx, ids!(hidden)).set_visible(cx, a.spoiler && state.is_empty());
            let edge = if a.spoiler { crate::theme::tok("accent", 1.0) } else { crate::theme::tok("gray_600", 1.0) };
            let mut tile = chip.widget(cx, ids!(tile));
            script_apply_eval!(cx, tile, {draw_bg +: {border_color: #(edge)}});
            let (eye_bg, eye_fg) = if a.spoiler {
                (crate::theme::tok("accent", 1.0), vec4(1.0, 1.0, 1.0, 1.0))
            } else {
                (vec4(0.0, 0.0, 0.0, 0.7), vec4(1.0, 1.0, 1.0, 0.8))
            };
            let mut eye = chip.widget(cx, ids!(eye));
            script_apply_eval!(cx, eye, {draw_bg +: {color: #(eye_bg)}});
            let mut eye_icon = chip.widget(cx, ids!(eye.icon));
            script_apply_eval!(cx, eye_icon, {draw_icon +: {color: #(eye_fg)}});
        }
        self.ui.view(cx, ids!(attach_bar)).redraw(cx);
    }

    /// Clears the chips, for a new channel or after sending.
    pub(crate) fn clear_attachments(&mut self, cx: &mut Cx) {
        self.attachments.clear();
        self.queued_send = None;
        self.preserving = None;
        self.show_attachments(cx);
    }

    /// Sends `text` with the files, now or once they're up.
    pub(crate) fn send_with_attachments(&mut self, cx: &mut Cx, text: String, reply_to: Option<String>, spoiler: bool) {
        self.queued_send = Some((text, reply_to, spoiler));
        self.flush_queued_send(cx);
        if self.queued_send.is_some() {
            self.notice(cx, "Uploading…");
        }
    }

    /// Sends `text` once its expiring `links` are saved as files.
    pub(crate) fn preserve_and_send(&mut self, cx: &mut Cx, links: Vec<String>, text: String, reply_to: Option<String>, spoiler: bool) {
        let waiting = links
            .into_iter()
            .map(|url| {
                let id = LiveId::unique();
                let mut req = HttpRequest::new(url.clone(), HttpMethod::GET);
                req.set_header("User-Agent".into(), "Inferno/0.1 (Nostr chat client)".into());
                cx.http_request(id, req);
                (id, url)
            })
            .collect();
        self.preserving = Some(Preserving { text, reply_to, spoiler, waiting, saved: Vec::new() });
        self.notice(cx, "Saving linked files…");
    }

    pub(crate) fn preserve_handle_event(&mut self, cx: &mut Cx, event: &Event) {
        let Event::NetworkResponses(responses) = event else { return };
        if self.preserving.is_none() {
            return;
        }
        for r in responses.iter() {
            let (id, response) = match r {
                NetworkResponse::HttpResponse { request_id, response } => (*request_id, Some(response)),
                NetworkResponse::HttpError { request_id, .. } => (*request_id, None),
                _ => continue,
            };
            let Some(p) = self.preserving.as_mut() else { return };
            let Some(at) = p.waiting.iter().position(|(w, _)| *w == id) else { continue };
            let (_, url) = p.waiting.remove(at);
            let name = link_file_name(&url);
            let bytes = response.filter(|r| (200..300).contains(&r.status_code)).and_then(|r| r.body.clone());
            match bytes {
                Some(bytes) => {
                    crate::media_cache::store(&url, bytes.clone());
                    let before = self.attachments.len();
                    self.add_attachment(cx, name, bytes.to_vec());
                    if self.attachments.len() > before {
                        if let Some(p) = self.preserving.as_mut() {
                            p.saved.push(url);
                        }
                    }
                }
                // Sent as it is: the link may still work for a while.
                None => self.toast(cx, &format!("Couldn't save {name}: the link has expired or can't be reached"), Toast::Error),
            }
        }
        if self.preserving.as_ref().is_some_and(|p| p.waiting.is_empty()) {
            let p = self.preserving.take().expect("checked");
            let mut text = p.text;
            for url in &p.saved {
                text = text.replace(&format!("<{url}>"), "").replace(url.as_str(), "");
            }
            let text = text.split('\n').map(str::trim_end).collect::<Vec<_>>().join("\n").trim().to_owned();
            self.notice(cx, "");
            if self.has_attachments() {
                self.send_with_attachments(cx, text, p.reply_to, p.spoiler);
            } else {
                self.send(backend::Command::Send { text, reply_to: p.reply_to, spoiler: p.spoiler, files: vec![] });
            }
        }
    }

    pub(crate) fn attachments_failed(&self) -> bool {
        self.attachments.iter().any(|a| a.failed)
    }

    fn flush_queued_send(&mut self, cx: &mut Cx) {
        if self.queued_send.is_none() || self.attachments.iter().any(|a| a.url.is_none()) {
            return;
        }
        let (text, reply_to, spoiler) = self.queued_send.take().expect("checked");
        let files = self.attachments.iter().filter_map(Attachment::meta).collect();
        self.send(backend::Command::Send { text, reply_to, spoiler, files });
        self.clear_attachments(cx);
        self.notice(cx, "");
    }

    pub(crate) fn attachments_handle_actions(&mut self, cx: &mut Cx, actions: &Actions) {
        for action in actions {
            let Some(fa) = action.downcast_ref::<FileDialogAction>() else { continue };
            match fa {
                FileDialogAction::FileLoaded { id, files } if *id == PICK => {
                    for f in files {
                        self.add_attachment(cx, f.name.clone(), f.bytes.to_vec());
                    }
                }
                FileDialogAction::FileSelected { id, paths } if *id == PICK => {
                    for p in paths {
                        match std::fs::read(p) {
                            Ok(bytes) => {
                                let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                                self.add_attachment(cx, name, bytes);
                            }
                            Err(e) => self.toast(cx, &format!("{}: {e}", p.display()), Toast::Error),
                        }
                    }
                }
                _ => {}
            }
        }
        if self.attachments.is_empty() {
            return;
        }
        let mut remove = None;
        let mut retry = None;
        let mut spoil = None;
        for (i, slot) in SLOTS.iter().enumerate().take(self.attachments.len()) {
            let chip = self.ui.view(cx, slot);
            if chip.view(cx, ids!(x)).finger_up(actions).is_some_and(|e| !e.cancelled && e.was_tap()) {
                remove = Some(i);
            } else if chip.view(cx, ids!(eye)).finger_up(actions).is_some_and(|e| !e.cancelled && e.was_tap()) {
                spoil = Some(i);
            } else if self.attachments[i].failed && chip.finger_up(actions).is_some_and(|e| !e.cancelled && e.was_tap()) {
                retry = Some(i);
            }
        }
        if let Some(i) = remove {
            self.attachments.remove(i);
            // The chips after it move up a slot: their pictures redraw.
            for a in &mut self.attachments[i..] {
                a.shown = false;
            }
            self.show_attachments(cx);
            self.flush_queued_send(cx);
        }
        if let Some(i) = spoil {
            self.attachments[i].spoiler = !self.attachments[i].spoiler;
            self.show_attachments(cx);
        }
        if let Some(i) = retry {
            let (bytes, mime) = (self.attachments[i].bytes.clone(), self.attachments[i].mime);
            let (upload, sha256) = self.uploads.start(uploads::Purpose::Attachment, bytes, mime);
            let a = &mut self.attachments[i];
            a.upload = upload;
            a.failed = false;
            self.send(backend::Command::UploadAuth { id: upload, sha256 });
            self.show_attachments(cx);
        }
    }

    pub(crate) fn has_attachments(&self) -> bool {
        !self.attachments.is_empty()
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn finds_expiring_links_and_names() {
        let link = "https://cdn.discordapp.com/attachments/1/2/RDT%20clip.mov?ex=6ac7&is=6ac5&hm=fa57&";
        let text = format!("look <{link}> and https://example.com/a.mp4, {link}");
        assert_eq!(super::expiring_links(&text), vec![link.to_owned()]);
        assert_eq!(super::link_file_name(link), "RDT clip.mov");
        assert_eq!(super::link_file_name("https://x.example/"), "x.example");
    }
}
