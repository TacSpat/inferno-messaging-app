//! What an extensionless Blossom link is (Flutter's HEAD check): until the
//! server answers it shows as an image, as before; a video, sound or other
//! file then redraws as its player or card.

use std::collections::HashMap;
use std::sync::Mutex;

use inferno_core::media::FileMeta;
use makepad_widgets::*;

enum State {
    Wanted,
    Asked,
    Known(String),
}

static PROBES: Mutex<Option<HashMap<String, State>>> = Mutex::new(None);
static IN_FLIGHT: Mutex<Option<HashMap<LiveId, String>>> = Mutex::new(None);

/// The file behind `url` if the server has said; asks on first sight.
pub fn lookup(url: &str) -> Option<FileMeta> {
    let mut probes = PROBES.lock().unwrap_or_else(|e| e.into_inner());
    let probes = probes.get_or_insert_with(HashMap::new);
    match probes.get(url) {
        Some(State::Known(mime)) => Some(FileMeta { url: url.to_owned(), mime: mime.clone(), ..Default::default() }),
        Some(_) => None,
        None => {
            probes.insert(url.to_owned(), State::Wanted);
            None
        }
    }
}

/// Sends the HEAD requests the last draw asked for.
pub fn send(cx: &mut Cx) {
    let mut probes = PROBES.lock().unwrap_or_else(|e| e.into_inner());
    let Some(probes) = probes.as_mut() else { return };
    let mut flight = IN_FLIGHT.lock().unwrap_or_else(|e| e.into_inner());
    let flight = flight.get_or_insert_with(HashMap::new);
    for (url, state) in probes.iter_mut() {
        if matches!(state, State::Wanted) {
            *state = State::Asked;
            let id = LiveId::unique();
            flight.insert(id, url.clone());
            cx.http_request(id, HttpRequest::new(url.clone(), HttpMethod::HEAD));
        }
    }
}

/// Takes the answers; true if any link's type is now known.
pub fn handle_event(event: &Event) -> bool {
    let Event::NetworkResponses(responses) = event else { return false };
    let mut changed = false;
    for r in responses.iter() {
        let (id, mime) = match r {
            NetworkResponse::HttpResponse { request_id, response } => (
                *request_id,
                response
                    .headers
                    .iter()
                    .find(|(k, _)| k.eq_ignore_ascii_case("content-type"))
                    .and_then(|(_, v)| v.first())
                    .filter(|_| (200..300).contains(&response.status_code))
                    .map(|v| v.split(';').next().unwrap_or("").trim().to_lowercase()),
            ),
            NetworkResponse::HttpError { request_id, .. } => (*request_id, None),
            _ => continue,
        };
        let Some(url) = IN_FLIGHT.lock().unwrap_or_else(|e| e.into_inner()).as_mut().and_then(|f| f.remove(&id)) else { continue };
        // An unanswered or generic type stays an image, as before.
        let mime = mime.filter(|m| !m.is_empty() && m != "application/octet-stream" && !m.starts_with("image/"));
        if let Some(probes) = PROBES.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
            changed |= mime.is_some();
            probes.insert(url, State::Known(mime.unwrap_or_else(|| "image/*".into())));
        }
    }
    changed
}
