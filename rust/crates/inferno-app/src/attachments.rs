//! Files for the next message (Rails' attach button and file preview).
//! Each goes up to Blossom as soon as it's picked; Send waits for any
//! still on their way, then their URLs follow the text with an imeta tag
//! each.

use inferno_core::media::{mime_for, FileMeta};
use makepad_widgets::*;

use crate::rich_input::RichInputWidgetRefExt;
use crate::{backend, uploads, App, Toast};

/// Rails' chips: as many as fit; we keep ten slots.
pub const MAX: usize = 10;
/// What a Blossom server is likely to take.
const MAX_BYTES: usize = 100 * 1024 * 1024;
const SLOTS: [&[LiveId]; MAX] = [ids!(a0), ids!(a1), ids!(a2), ids!(a3), ids!(a4), ids!(a5), ids!(a6), ids!(a7), ids!(a8), ids!(a9)];
const PICK: LiveId = live_id!(pick_attach);

pub struct Attachment {
    upload: u64,
    name: String,
    mime: &'static str,
    bytes: Vec<u8>,
    url: Option<String>,
    failed: bool,
    /// The chip's picture is decoded (once).
    shown: bool,
}

impl Attachment {
    fn meta(&self) -> Option<FileMeta> {
        Some(FileMeta {
            url: self.url.clone()?,
            mime: self.mime.to_owned(),
            name: self.name.clone(),
            size: Some(self.bytes.len() as u64),
            dim: None,
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

    fn add_attachment(&mut self, cx: &mut Cx, name: String, bytes: Vec<u8>) {
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
        self.attachments.push(Attachment { upload, name, mime, bytes, url: None, failed: false, shown: false });
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
            thumb.set_visible(cx, picture && a.shown);
            chip.label(cx, ids!(name)).set_visible(cx, !(picture && a.shown));
            chip.label(cx, ids!(name)).set_text(cx, &a.name);
            let state = if a.failed {
                "Upload failed, click to retry"
            } else if a.url.is_none() {
                "Uploading…"
            } else {
                ""
            };
            chip.label(cx, ids!(state)).set_visible(cx, !state.is_empty());
            chip.label(cx, ids!(state)).set_text(cx, state);
        }
        self.ui.view(cx, ids!(attach_bar)).redraw(cx);
    }

    /// Clears the chips, for a new channel or after sending.
    pub(crate) fn clear_attachments(&mut self, cx: &mut Cx) {
        self.attachments.clear();
        self.queued_send = None;
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
        for (i, slot) in SLOTS.iter().enumerate().take(self.attachments.len()) {
            let chip = self.ui.view(cx, slot);
            if chip.view(cx, ids!(x)).finger_up(actions).is_some_and(|e| !e.cancelled && e.was_tap()) {
                remove = Some(i);
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
