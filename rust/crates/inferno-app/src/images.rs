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
    let loaded = load_image_from_cache(cx, Path::new(url)).is_some();
    img.set_visible(cx, loaded);
    if loaded {
        let _ = img.load_image_http_by_url_async(cx, url);
        return;
    }
    let loading = cx.has_global::<ImageCache>() && cx.get_global::<ImageCache>().map.contains_key(Path::new(url));
    if !loaded && !loading {
        let mut tried = TRIED.lock().unwrap_or_else(|e| e.into_inner());
        let tried = tried.get_or_insert_with(HashMap::new);
        match tried.get(url) {
            // Asked before, not in the cache now: it failed. Wait a while.
            Some(at) if at.elapsed() < RETRY_AFTER => return,
            _ => {
                tried.insert(url.to_owned(), Instant::now());
            }
        }
    }
    if !loading {
        // Starts the download; the shared cache keeps it once decoded.
        let _ = load_image_http_by_url_async(cx, url);
    }
}

/// Downloads and decodes finish through whichever image widget sees the
/// event, and hidden ones see none; the app handles them itself. True when
/// an image became ready, so the UI should redraw.
pub fn handle_event(cx: &mut Cx, event: &Event) -> bool {
    match event {
        Event::NetworkResponses(e) => {
            handle_image_cache_network_responses(cx, e);
            false
        }
        Event::Actions(actions) => {
            let mut ready = false;
            for action in actions {
                if let Some(AsyncImageLoad { image_path, result }) = action.downcast_ref() {
                    if let Some(result) = result.borrow_mut().take() {
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
