//! The clipboard beyond text, which Makepad's clipboard can't do (arboard):
//!
//! - Rails' Copy Image (message menu): the picture itself, not its link. It
//!   is downloaded, then decoded (Makepad's decoders, any format it shows)
//!   and handed over off the UI thread.
//! - Pasting into the composer (Rails' paste handler): text pastes as text;
//!   with no text, a picture becomes an attachment (`image.png`). Files
//!   copied in a file manager attach as files, ahead of the paths they also
//!   put on the clipboard as text.

use std::sync::Mutex;

use makepad_widgets::*;

use crate::{App, Toast};

/// One clipboard for the app's life: on X11 the copied picture is served
/// from it until something else is copied.
static CLIPBOARD: Mutex<Option<arboard::Clipboard>> = Mutex::new(None);

/// Files a paste brought, read off the UI thread: (name, bytes) each, or
/// why not.
#[derive(Debug, Clone)]
pub struct Pasted(pub Result<Vec<(String, Vec<u8>)>, String>);

fn with_clipboard<T>(f: impl FnOnce(&mut arboard::Clipboard) -> T) -> Result<T, String> {
    let mut clipboard = CLIPBOARD.lock().unwrap_or_else(|e| e.into_inner());
    if clipboard.is_none() {
        *clipboard = Some(arboard::Clipboard::new().map_err(|e| e.to_string())?);
    }
    Ok(f(clipboard.as_mut().expect("just made")))
}

/// The files copied in a file manager (not folders).
fn copied_files() -> Vec<std::path::PathBuf> {
    with_clipboard(|c| c.get().file_list().unwrap_or_default())
        .unwrap_or_default()
        .into_iter()
        .filter(|p| p.is_file())
        .collect()
}

fn has_text() -> bool {
    with_clipboard(|c| c.get_text().is_ok_and(|t| !t.is_empty())).unwrap_or(false)
}

/// The clipboard's picture as a PNG.
fn pasted_png() -> Result<Vec<u8>, String> {
    use ::makepad_zune_png::makepad_zune_core::{bit_depth::BitDepth, colorspace::ColorSpace, options::EncoderOptions};
    let image = with_clipboard(|c| c.get_image())?.map_err(|e| e.to_string())?;
    let options = EncoderOptions::default()
        .set_width(image.width)
        .set_height(image.height)
        .set_depth(BitDepth::Eight)
        .set_colorspace(ColorSpace::RGBA);
    let mut png = Vec::new();
    ::makepad_zune_png::PngEncoder::new(&image.bytes, options).encode(&mut png).map_err(|e| format!("{e:?}"))?;
    Ok(png)
}

/// A copy finished (posted from the worker thread).
#[derive(Debug, Clone)]
pub enum CopyImageDone {
    Copied,
    Failed(String),
}

/// `0xAARRGGBB` pixels (Makepad's decoded images) as RGBA bytes.
pub fn argb_to_rgba(pixels: &[u32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(pixels.len() * 4);
    for p in pixels {
        out.extend_from_slice(&[(p >> 16) as u8, (p >> 8) as u8, *p as u8, (p >> 24) as u8]);
    }
    out
}

fn put_on_clipboard(bytes: &[u8]) -> Result<(), String> {
    let image = makepad_widgets::makepad_draw::image_cache::decode_image_from_data(bytes)
        .map_err(|e| format!("couldn't read the picture ({e:?})"))?;
    let rgba = argb_to_rgba(&image.data[..image.width * image.height]);
    let data = arboard::ImageData { width: image.width, height: image.height, bytes: rgba.into() };
    with_clipboard(|c| c.set_image(data))?.map_err(|e| e.to_string())
}

impl App {
    /// Starts copying the picture at `url`.
    pub(crate) fn copy_image(&mut self, cx: &mut Cx, url: &str) {
        let id = LiveId::unique();
        let mut req = HttpRequest::new(url.to_owned(), HttpMethod::GET);
        req.set_header("User-Agent".into(), "Inferno/0.1 (Nostr chat client)".into());
        cx.http_request(id, req);
        self.copy_image_req = Some(id);
    }

    pub(crate) fn copy_image_handle_event(&mut self, cx: &mut Cx, event: &Event) {
        let (Event::NetworkResponses(responses), Some(id)) = (event, self.copy_image_req) else { return };
        for r in responses.iter() {
            match r {
                NetworkResponse::HttpResponse { request_id, response } if *request_id == id => {
                    self.copy_image_req = None;
                    let ok = (200..300).contains(&response.status_code);
                    let Some(bytes) = response.body.clone().filter(|_| ok) else {
                        self.toast(cx, "Couldn't copy the image", Toast::Error);
                        return;
                    };
                    std::thread::spawn(move || {
                        let done = match put_on_clipboard(&bytes) {
                            Ok(()) => CopyImageDone::Copied,
                            Err(e) => CopyImageDone::Failed(e),
                        };
                        Cx::post_action(done);
                    });
                }
                NetworkResponse::HttpError { request_id, .. } if *request_id == id => {
                    self.copy_image_req = None;
                    self.toast(cx, "Couldn't download the image", Toast::Error);
                }
                _ => {}
            }
        }
    }

    /// Ctrl+V (or Shift+Insert) in the composer. True when the paste is
    /// files: the text paste on its way (their paths) is to be dropped.
    pub(crate) fn paste_into_composer(&mut self) -> bool {
        // Asked off the UI thread, and only briefly waited for: when we own
        // the clipboard ourselves (a link we just copied), only this thread's
        // event loop can answer, so waiting here would freeze the app.
        let (tx, rx) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            let files = copied_files();
            let text = files.is_empty() && has_text();
            let _ = tx.send((files, text));
        });
        let Ok((files, text)) = rx.recv_timeout(std::time::Duration::from_millis(250)) else {
            // No answer yet: it's text (ours), which Makepad pastes itself.
            return false;
        };
        if !files.is_empty() {
            std::thread::spawn(move || {
                let read: Result<Vec<_>, String> = files
                    .iter()
                    .map(|p| {
                        let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                        std::fs::read(p).map(|bytes| (name, bytes)).map_err(|e| format!("{}: {e}", p.display()))
                    })
                    .collect();
                Cx::post_action(Pasted(read));
            });
            return true;
        }
        // Rails: text on the clipboard is a text paste.
        if text {
            return false;
        }
        std::thread::spawn(|| {
            // No picture either: nothing to paste (not an error).
            let pasted = match pasted_png() {
                Ok(png) => Ok(vec![("image.png".to_owned(), png)]),
                Err(_) => Ok(Vec::new()),
            };
            Cx::post_action(Pasted(pasted));
        });
        false
    }

    pub(crate) fn copy_image_handle_actions(&mut self, cx: &mut Cx, actions: &Actions) {
        for action in actions {
            if let Some(Pasted(pasted)) = action.downcast_ref::<Pasted>() {
                match pasted.clone() {
                    Ok(files) => {
                        for (name, bytes) in files {
                            self.add_attachment(cx, name, bytes);
                        }
                    }
                    Err(e) => self.toast(cx, &format!("Couldn't paste: {e}"), Toast::Error),
                }
            }
            match action.downcast_ref::<CopyImageDone>() {
                Some(CopyImageDone::Copied) => self.toast(cx, "Image copied", Toast::Success),
                Some(CopyImageDone::Failed(e)) => {
                    let e = e.clone();
                    self.toast(cx, &format!("Couldn't copy the image: {e}"), Toast::Error);
                }
                None => {}
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn pixels_become_rgba() {
        assert_eq!(super::argb_to_rgba(&[0x80112233]), vec![0x11, 0x22, 0x33, 0x80]);
    }
}
