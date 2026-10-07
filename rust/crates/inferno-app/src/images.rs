//! Profile pictures and banners. Makepad's image cache fetches, decodes and
//! shares one texture per URL; this decides what may be fetched and keeps a
//! dead link from being re-requested on every frame (the cache forgets a
//! failed URL, so asking again would fetch it again).

use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use makepad_widgets::*;

/// How long a URL that didn't load is left alone.
const RETRY_AFTER: Duration = Duration::from_secs(300);

static TRIED: Mutex<Option<HashMap<String, Instant>>> = Mutex::new(None);

/// Our downloads in flight: request id → URL. Makepad's own image loader
/// can't send a User-Agent, and some hosts (Wikimedia, for one) refuse
/// requests without one, so we fetch and hand the bytes to its decoder.
static PENDING: Mutex<Option<HashMap<LiveId, String>>> = Mutex::new(None);

/// URLs that didn't download or decode, so lists can leave them out.
static FAILED: Mutex<Option<std::collections::HashSet<String>>> = Mutex::new(None);

fn mark_failed(url: &str) {
    FAILED.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(Default::default).insert(url.to_owned());
}

/// Whether `url` failed to load (this run).
pub fn failed(url: &str) -> bool {
    FAILED.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|f| f.contains(url))
}

const USER_AGENT: &str = "Inferno/0.1 (Nostr chat client)";
/// Bigger downloads are refused (animated GIFs can be large).
const MAX_DOWNLOAD: usize = 25 * 1024 * 1024;

fn pending_has(url: &str) -> bool {
    PENDING.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new).values().any(|u| u == url)
}

fn fetch(cx: &mut Cx, url: &str) {
    let mut req = HttpRequest::new(url.to_owned(), HttpMethod::GET);
    req.set_header("User-Agent".into(), USER_AGENT.into());
    req.set_max_response_body_bytes(MAX_DOWNLOAD as u64);
    let id = LiveId::unique();
    PENDING.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new).insert(id, url.to_owned());
    cx.http_request(id, req);
}

/// Only web images; nothing local, no data: or custom schemes.
pub fn allowed(url: &str) -> bool {
    (url.starts_with("https://") || url.starts_with("http://")) && url.len() < 2048 && !url.contains(char::is_whitespace)
}

/// Shows `url` in `img` once it's loaded, over the letter avatar or colour
/// banner beneath it; hidden until then (an image with no texture draws
/// black). The app redraws when a download finishes (`handle_event`).
pub fn show(cx: &mut Cx, img: &ImageRef, url: Option<&str>) {
    let Some(url) = url.filter(|u| allowed(u)) else {
        img.set_visible(cx, false);
        return;
    };
    let loaded = ensure(cx, url);
    img.set_visible(cx, loaded);
    if loaded {
        let _ = img.load_image_http_by_url_async(cx, url);
    }
}

/// Starts fetching `url` if it isn't loaded or on its way; true once it's
/// in the image cache (for drawing it without an Image widget).
pub fn ensure(cx: &mut Cx, url: &str) -> bool {
    if !allowed(url) {
        return false;
    }
    if load_image_from_cache(cx, Path::new(url)).is_some() {
        return true;
    }
    let loading = pending_has(url) || (cx.has_global::<ImageCache>() && cx.get_global::<ImageCache>().map.contains_key(Path::new(url)));
    if !loading {
        let mut tried = TRIED.lock().unwrap_or_else(|e| e.into_inner());
        let tried = tried.get_or_insert_with(HashMap::new);
        match tried.get(url) {
            // Asked before, not in the cache now: it failed. Wait a while.
            Some(at) if at.elapsed() < RETRY_AFTER => return false,
            _ => {
                tried.insert(url.to_owned(), Instant::now());
            }
        }
        // Starts the download; the shared cache keeps it once decoded.
        fetch(cx, url);
    }
    false
}

/// Downloads and decodes finish through whichever image widget sees the
/// event, and hidden ones see none; the app handles them itself. True when
/// an image became ready, so the UI should redraw.
pub fn handle_event(cx: &mut Cx, event: &Event) -> bool {
    match event {
        Event::NetworkResponses(e) => {
            handle_image_cache_network_responses(cx, e);
            let mut failures = false;
            for r in e.iter() {
                let (id, body) = match r {
                    NetworkResponse::HttpResponse { request_id, response } => (
                        *request_id,
                        (200..300).contains(&response.status_code).then(|| response.body.clone()).flatten(),
                    ),
                    NetworkResponse::HttpError { request_id, .. } => (*request_id, None),
                    _ => continue,
                };
                let url = PENDING.lock().unwrap_or_else(|e| e.into_inner()).get_or_insert_with(HashMap::new).remove(&id);
                let Some(url) = url else { continue };
                let Some(body) = body else {
                    mark_failed(&url);
                    failures = true;
                    continue;
                };
                // Decoded off the UI thread; the result comes back as an
                // AsyncImageLoad action (handled below).
                let _ = load_image_from_data_async(cx, Path::new(&url), body);
            }
            failures
        }
        Event::Actions(actions) => {
            let mut ready = false;
            for action in actions {
                if let Some(AsyncImageLoad { image_path, result }) = action.downcast_ref() {
                    if let Some(result) = result.borrow_mut().take() {
                        if result.is_err() {
                            mark_failed(&image_path.to_string_lossy());
                        }
                        process_async_image_load(cx, image_path, result);
                    }
                    ready = true;
                }
            }
            ready
        }
        _ => false,
    }
}
