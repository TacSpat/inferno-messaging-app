//! GIF search through KLIPY (Tenor's API shut down on 2026-06-30). The key
//! comes from `INFERNO_KLIPY_KEY` (at run time, or baked in at build time);
//! without one, the picker uses GIFs shared on Nostr instead.
//! `INFERNO_KLIPY_BASE` points it elsewhere (a local stub in tests).

use std::collections::HashMap;

use inferno_core::gif_search::{self, Page, Query};
use makepad_widgets::*;

pub struct GifService {
    key: Option<String>,
    base: String,
    customer: String,
    /// Request id → (sequence number, query).
    pending: HashMap<LiveId, (u64, Query)>,
    seq: u64,
}

impl Default for GifService {
    fn default() -> Self {
        let key = std::env::var("INFERNO_KLIPY_KEY")
            .ok()
            .or_else(|| option_env!("INFERNO_KLIPY_KEY").map(str::to_owned))
            .filter(|k| !k.trim().is_empty());
        let base = std::env::var("INFERNO_KLIPY_BASE").unwrap_or_else(|_| gif_search::KLIPY_BASE.into());
        GifService { key, base, customer: customer_id(), pending: HashMap::new(), seq: 0 }
    }
}

/// A random id for this install, kept in the config dir: KLIPY's per-user
/// recents without telling it who we are.
fn customer_id() -> String {
    let path = crate::picker::file("gif-customer");
    if let Some(id) = path.as_ref().and_then(|p| std::fs::read_to_string(p).ok()).filter(|s| s.len() == 32) {
        return id;
    }
    let id = inferno_core::blossom::sha256_hex(format!("{:?}{}", std::time::SystemTime::now(), std::process::id()).as_bytes())[..32].to_owned();
    if let Some(p) = path {
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let _ = std::fs::write(p, &id);
    }
    id
}

impl GifService {
    pub fn has_key(&self) -> bool {
        self.key.is_some()
    }

    /// Starts a query; its answer supersedes any earlier one.
    pub fn request(&mut self, cx: &mut Cx, q: Query) {
        let Some(key) = self.key.clone() else { return };
        self.seq += 1;
        let url = gif_search::klipy_url(&self.base, &key, &q, 1, &self.customer);
        let mut req = HttpRequest::new(url, HttpMethod::GET);
        req.set_header("User-Agent".into(), "Inferno/0.1 (Nostr chat client)".into());
        let id = LiveId::unique();
        self.pending.insert(id, (self.seq, q));
        cx.http_request(id, req);
    }

    /// Answers to the latest query (older ones are dropped).
    pub fn handle_event(&mut self, event: &Event) -> Option<(Query, Result<Page, String>)> {
        let Event::NetworkResponses(responses) = event else { return None };
        let mut out = None;
        for r in responses.iter() {
            let (id, result) = match r {
                NetworkResponse::HttpResponse { request_id, response } => {
                    let body = response.body.as_ref().map(|b| String::from_utf8_lossy(b).into_owned()).unwrap_or_default();
                    let result = if (200..300).contains(&response.status_code) {
                        gif_search::parse_klipy(&body)
                    } else {
                        Err(gif_search::parse_klipy(&body).err().unwrap_or_else(|| format!("the GIF service answered {}", response.status_code)))
                    };
                    (*request_id, result)
                }
                NetworkResponse::HttpError { request_id, .. } => (*request_id, Err("couldn't reach the GIF service".into())),
                _ => continue,
            };
            if let Some((seq, q)) = self.pending.remove(&id) {
                if seq == self.seq {
                    out = Some((q, result));
                }
            }
        }
        out
    }
}
