//! Blossom uploads (BUD-01/02): the signed authorization and the response.
//! The bytes themselves go out through the app's HTTP layer.
//!
//! Rails uploaded server-side, signed by the server owner's key; Flutter
//! signed with the user's own key, which is what Blossom expects and what
//! this does. The server list is the user's NIP-B7 list (kind 10063),
//! defaulting to Rails' two servers.

use base64::Engine;
use nostr_sdk::prelude::*;
use sha2::{Digest, Sha256};

/// Rails' defaults (`LocalConfig.blossom_server_urls`).
pub const DEFAULT_SERVERS: &[&str] = &["https://blossom.primal.net", "https://cdn.satellite.earth"];

/// How long an upload authorization is good for (Rails: 5 minutes).
const AUTH_TTL_SECS: u64 = 300;

pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// The `Authorization` header value for uploading a blob with this hash.
pub fn upload_auth(keys: &Keys, sha256: &str, now: Timestamp) -> Result<String, String> {
    let expiration = Timestamp::from(now.as_secs() + AUTH_TTL_SECS);
    let event = EventBuilder::new(Kind::BlossomAuth, format!("Upload {sha256}"))
        .tags([
            Tag::parse(["t", "upload"]).map_err(|e| e.to_string())?,
            Tag::parse(["x", sha256]).map_err(|e| e.to_string())?,
            Tag::expiration(expiration),
        ])
        .custom_created_at(now)
        .finalize(keys)
        .map_err(|e| e.to_string())?;
    Ok(format!("Nostr {}", base64::engine::general_purpose::STANDARD.encode(event.as_json())))
}

/// Where an uploaded blob lives: the descriptor's `url`, else
/// `<server>/<sha256>` (Rails' fallback).
pub fn uploaded_url(server: &str, sha256: &str, response_body: &[u8]) -> String {
    serde_json::from_slice::<serde_json::Value>(response_body)
        .ok()
        .and_then(|v| v.get("url").and_then(|u| u.as_str()).map(str::to_owned))
        .filter(|u| u.starts_with("https://") || u.starts_with("http://"))
        .unwrap_or_else(|| format!("{}/{sha256}", server.trim_end_matches('/')))
}

/// The user's servers from their NIP-B7 list, in order.
pub fn servers_from_list(event: &Event) -> Vec<String> {
    event
        .tags
        .iter()
        .filter_map(|t| {
            let s = t.as_slice();
            (s.first().map(String::as_str) == Some("server")).then(|| s.get(1).cloned()).flatten()
        })
        .filter(|u| u.starts_with("https://") || u.starts_with("http://"))
        .collect()
}

pub fn server_list(keys: &Keys, servers: &[String]) -> Result<Event, String> {
    let tags: Vec<Tag> = servers.iter().filter_map(|s| Tag::parse(["server", s.as_str()]).ok()).collect();
    EventBuilder::new(Kind::BlossomServerList, "").tags(tags).finalize(keys).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_is_a_signed_upload_event_for_this_hash() {
        let keys = Keys::generate();
        let sha = sha256_hex(b"hello");
        assert_eq!(sha, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
        let header = upload_auth(&keys, &sha, Timestamp::from(1_000)).unwrap();
        let json = base64::engine::general_purpose::STANDARD.decode(header.strip_prefix("Nostr ").unwrap()).unwrap();
        let event = Event::from_json(json).unwrap();
        event.verify().unwrap();
        assert_eq!(event.kind, Kind::BlossomAuth);
        assert_eq!(event.pubkey, keys.public_key());
        let tag = |k: &str| event.tags.iter().find(|t| t.as_slice()[0] == k).map(|t| t.as_slice()[1].clone());
        assert_eq!(tag("t").as_deref(), Some("upload"));
        assert_eq!(tag("x").as_deref(), Some(sha.as_str()));
        assert_eq!(tag("expiration").as_deref(), Some("1300"));
    }

    #[test]
    fn url_from_descriptor_or_fallback() {
        let body = br#"{"url":"https://cdn.example/abc.png","sha256":"abc"}"#;
        assert_eq!(uploaded_url("https://cdn.example", "abc", body), "https://cdn.example/abc.png");
        assert_eq!(uploaded_url("https://cdn.example/", "abc", b"oops"), "https://cdn.example/abc");
    }

    #[test]
    fn server_list_round_trips() {
        let keys = Keys::generate();
        let servers = vec!["https://a.example".to_owned(), "https://b.example".to_owned()];
        assert_eq!(servers_from_list(&server_list(&keys, &servers).unwrap()), servers);
    }
}
