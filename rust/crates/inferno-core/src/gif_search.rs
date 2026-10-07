//! GIF search now that Tenor's API is gone (shut down 2026-06-30): KLIPY,
//! a near drop-in from former Tenor people, when there's a key; and GIFs
//! shared on Nostr (NIP-94 kind 1063 file metadata), which need none.
//!
//! The app does the HTTP (Makepad's client); this builds the requests and
//! reads the answers, so it can be tested without the network.

use nostr::prelude::*;
use serde_json::Value;

use crate::gifs::Gif;

pub const KLIPY_BASE: &str = "https://api.klipy.com";
/// KLIPY's page size bounds are 8..=50.
pub const PER_PAGE: u32 = 24;

#[derive(Debug, Clone, PartialEq)]
pub enum Query {
    Trending,
    Search(String),
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Page {
    pub gifs: Vec<Gif>,
    /// The next page number, if there is one.
    pub next: Option<u32>,
}

fn encode(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            b' ' => "+".into(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

/// The request URL. `customer` is an opaque per-install id KLIPY uses for
/// per-user recents; never a Nostr key.
pub fn klipy_url(base: &str, key: &str, q: &Query, page: u32, customer: &str) -> String {
    let base = base.trim_end_matches('/');
    let key = encode(key);
    let common = format!("page={page}&per_page={PER_PAGE}&customer_id={}&rating=pg-13", encode(customer));
    match q {
        Query::Trending => format!("{base}/api/v1/{key}/gifs/trending?{common}"),
        Query::Search(text) => format!("{base}/api/v1/{key}/gifs/search?q={}&{common}", encode(text.trim())),
    }
}

/// Reads a KLIPY page: `{result, data: {data: [...], current_page, has_next}}`,
/// each item's sizes under `file` (or `files`): hd/md/sm/xs, each with
/// gif/webp/mp4 `{url, width, height}`. Sends the md GIF, previews the sm one.
pub fn parse_klipy(body: &str) -> Result<Page, String> {
    let v: Value = serde_json::from_str(body).map_err(|e| format!("bad response: {e}"))?;
    if v.get("result").and_then(Value::as_bool) == Some(false) {
        let msg = v.get("message").and_then(Value::as_str).unwrap_or("the GIF service refused the request");
        return Err(msg.to_owned());
    }
    let data = v.get("data").ok_or("bad response: no data")?;
    let items = data.get("data").and_then(Value::as_array).ok_or("bad response: no items")?;
    let pick = |files: &Value, sizes: &[&str]| -> Option<String> {
        sizes.iter().find_map(|s| files.get(s)?.get("gif")?.get("url")?.as_str().map(str::to_owned))
    };
    let gifs = items
        .iter()
        .filter_map(|it| {
            let files = it.get("file").or_else(|| it.get("files"))?;
            let url = pick(files, &["md", "hd", "sm", "xs"])?;
            let preview = pick(files, &["sm", "xs", "md"]).unwrap_or_else(|| url.clone());
            Some(Gif { url, preview })
        })
        .collect();
    let current = data.get("current_page").and_then(Value::as_u64).unwrap_or(1) as u32;
    let next = data.get("has_next").and_then(Value::as_bool).unwrap_or(false).then_some(current + 1);
    Ok(Page { gifs, next })
}

/// The relay filter for shared GIFs (NIP-94, `m` = image/gif).
pub fn nostr_filter(limit: usize) -> Filter {
    Filter::new()
        .kind(Kind::FileMetadata)
        .custom_tag(SingleLetterTag::from_char('m').expect("m is a tag letter"), "image/gif")
        .limit(limit)
}

/// https, or http to this machine (local testing).
fn usable(url: &str) -> bool {
    url.starts_with("https://") || url.starts_with("http://127.0.0.1") || url.starts_with("http://localhost")
}

/// Shared GIFs matching every word of `query` in their description,
/// summary, alt text or hashtags (newest first, one per URL). An empty
/// query matches all.
pub fn nostr_gifs(events: &[Event], query: &str) -> Vec<Gif> {
    let words: Vec<String> = query.split_whitespace().map(str::to_lowercase).collect();
    let mut sorted: Vec<&Event> = events.iter().filter(|e| e.kind == Kind::FileMetadata).collect();
    sorted.sort_by(|a, b| b.created_at.cmp(&a.created_at));
    let mut out: Vec<Gif> = Vec::new();
    for e in sorted {
        let tag = |name: &str| e.tags.iter().find(|t| t.kind().to_string() == name).and_then(|t| t.content()).map(str::to_owned);
        let Some(url) = tag("url").filter(|u| usable(u)) else { continue };
        if tag("m").as_deref() != Some("image/gif") {
            continue;
        }
        let mut text = e.content.to_lowercase();
        for name in ["summary", "alt"] {
            if let Some(s) = tag(name) {
                text.push(' ');
                text.push_str(&s.to_lowercase());
            }
        }
        for t in e.tags.iter().filter(|t| t.kind().to_string() == "t") {
            if let Some(s) = t.content() {
                text.push(' ');
                text.push_str(&s.to_lowercase());
            }
        }
        if !words.iter().all(|w| text.contains(w.as_str())) || out.iter().any(|g| g.url == url) {
            continue;
        }
        let preview = tag("thumb").filter(|u| usable(u)).unwrap_or_else(|| url.clone());
        out.push(Gif { url, preview });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builds_klipy_requests() {
        let url = klipy_url("https://api.klipy.com/", "KEY", &Query::Search("happy cat & dog".into()), 2, "abc");
        assert_eq!(url, "https://api.klipy.com/api/v1/KEY/gifs/search?q=happy+cat+%26+dog&page=2&per_page=24&customer_id=abc&rating=pg-13");
        assert!(klipy_url(KLIPY_BASE, "KEY", &Query::Trending, 1, "abc").contains("/gifs/trending?page=1"));
    }

    #[test]
    fn reads_klipy_pages() {
        let body = r#"{"result":true,"data":{"data":[
            {"id":1,"title":"cat","file":{"hd":{"gif":{"url":"https://static.klipy.com/hd.gif"}},
                "md":{"gif":{"url":"https://static.klipy.com/md.gif","width":320,"height":240}},
                "sm":{"gif":{"url":"https://static.klipy.com/sm.gif"}}}},
            {"id":2,"files":{"xs":{"gif":{"url":"https://static.klipy.com/xs.gif"}}}},
            {"id":3,"title":"no files"}
        ],"current_page":1,"per_page":24,"has_next":true}}"#;
        let page = parse_klipy(body).unwrap();
        assert_eq!(page.gifs[0], Gif { url: "https://static.klipy.com/md.gif".into(), preview: "https://static.klipy.com/sm.gif".into() });
        assert_eq!(page.gifs[1].url, "https://static.klipy.com/xs.gif");
        assert_eq!(page.gifs.len(), 2);
        assert_eq!(page.next, Some(2));
        assert!(parse_klipy(r#"{"result":false,"message":"Invalid API key"}"#).unwrap_err().contains("Invalid"));
    }

    #[test]
    fn finds_shared_gifs_on_nostr() {
        let keys = Keys::generate();
        let gif = |url: &str, text: &str, m: &str| {
            EventBuilder::new(Kind::FileMetadata, text)
                .tags([Tag::parse(["url", url]).unwrap(), Tag::parse(["m", m]).unwrap(), Tag::parse(["t", "reaction"]).unwrap()])
                .finalize(&keys)
                .unwrap()
        };
        let events = vec![
            gif("https://b.example/dance.gif", "Happy dance", "image/gif"),
            gif("https://b.example/cat.gif", "a cat", "image/gif"),
            gif("https://b.example/pic.png", "happy png", "image/png"),
            gif("http://b.example/insecure.gif", "happy", "image/gif"),
        ];
        let found = nostr_gifs(&events, "happy");
        assert_eq!(found.iter().map(|g| g.url.as_str()).collect::<Vec<_>>(), ["https://b.example/dance.gif"]);
        assert_eq!(nostr_gifs(&events, "reaction").len(), 2, "hashtags count");
        assert_eq!(nostr_gifs(&events, "").len(), 2);
    }
}
