//! Linked videos kept on this device. A video linked from elsewhere (not a
//! Blossom blob) can vanish: Discord's attachment links expire after a day,
//! sites go away. The first time one's card loads, the whole file is saved
//! here, and every player after that plays the saved copy, so a link that
//! dies later still plays. Signed links are matched by their file, not
//! their signature, so a fresh link to the same file finds the copy too.
//!
//! Up to `CAP` on disk; the copies played longest ago go first.

use makepad_widgets::*;
use std::cell::RefCell;
use std::collections::HashMap;
use std::path::PathBuf;

const CAP: u64 = 2 * 1024 * 1024 * 1024;

thread_local! {
    /// Downloads on their way: request → link.
    static PENDING: RefCell<HashMap<LiveId, String>> = RefCell::new(HashMap::new());
}

/// `~/.local/share/inferno/media-<profile>/`
fn dir() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))?;
    let profile = std::env::var("INFERNO_PROFILE").unwrap_or_else(|_| "default".into());
    Some(base.join("inferno").join(format!("media-{profile}")))
}

/// A link that stops working by itself: Discord's attachment links, and
/// signed (pre-authorised) storage links.
pub fn expires(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://").or_else(|| url.strip_prefix("http://")) else { return false };
    let (host, path) = rest.split_once('/').unwrap_or((rest, ""));
    let query = url.split_once('?').map(|(_, q)| q).unwrap_or("");
    let discord = matches!(host, "cdn.discordapp.com" | "media.discordapp.net") && path.starts_with("attachments/");
    let signed = query.contains("X-Amz-Signature=") || query.contains("X-Goog-Signature=") || (query.contains("Expires=") && query.contains("Signature="));
    discord || signed
}

/// What names the file: an expiring link's signature changes, its file doesn't.
fn canonical(url: &str) -> &str {
    if expires(url) { url.split(['?', '#']).next().unwrap_or(url) } else { url }
}

fn path_for(url: &str) -> Option<PathBuf> {
    let key = canonical(url);
    let hash = inferno_core::blossom::sha256_hex(key.as_bytes());
    let file = key.rsplit('/').next().unwrap_or("");
    let ext = file.rsplit_once('.').map(|(_, e)| e.to_lowercase()).filter(|e| e.len() <= 5 && e.chars().all(|c| c.is_ascii_alphanumeric()));
    let name = match ext {
        Some(e) => format!("{}.{e}", &hash[..32]),
        None => hash[..32].to_owned(),
    };
    Some(dir()?.join(name))
}

/// Worth a copy: a web link that isn't a Blossom blob (those are named by
/// their content, and any server holding the blob serves it).
fn worth_keeping(url: &str) -> bool {
    (url.starts_with("https://") || url.starts_with("http://")) && !crate::message_format::is_blob(url)
}

/// The saved copy of `url`, if there is one.
pub fn saved(url: &str) -> Option<PathBuf> {
    path_for(url).filter(|p| p.is_file())
}

/// Where a player should read `url` from: the saved copy if there is one.
pub fn source(url: &str) -> VideoDataSource {
    match saved(url) {
        Some(path) => {
            // Played now: last to go when the cache is full.
            let _ = std::fs::File::options().append(true).open(&path).and_then(|f| f.set_modified(std::time::SystemTime::now()));
            VideoDataSource::Filesystem { path: path.to_string_lossy().into_owned() }
        }
        None => VideoDataSource::Network { url: url.to_owned() },
    }
}

/// Saves a copy of the video at `url` unless there is one (or one is on its way).
pub fn keep(cx: &mut Cx, url: &str) {
    if !worth_keeping(url) || saved(url).is_some() {
        return;
    }
    let pending = PENDING.with(|p| p.borrow().values().any(|u| canonical(u) == canonical(url)));
    if pending {
        return;
    }
    let id = LiveId::unique();
    let mut req = HttpRequest::new(url.to_owned(), HttpMethod::GET);
    req.set_header("User-Agent".into(), "Inferno/0.1 (Nostr chat client)".into());
    cx.http_request(id, req);
    PENDING.with(|p| p.borrow_mut().insert(id, url.to_owned()));
}

/// Stores a copy that came another way (a link saved when sending).
pub fn store(url: &str, bytes: std::sync::Arc<[u8]>) {
    if !worth_keeping(url) {
        return;
    }
    let Some(path) = path_for(url) else { return };
    std::thread::spawn(move || write(&path, &bytes));
}

pub fn handle_event(event: &Event) {
    let Event::NetworkResponses(responses) = event else { return };
    for r in responses.iter() {
        let (id, response) = match r {
            NetworkResponse::HttpResponse { request_id, response } => (*request_id, Some(response)),
            NetworkResponse::HttpError { request_id, .. } => (*request_id, None),
            _ => continue,
        };
        let Some(url) = PENDING.with(|p| p.borrow_mut().remove(&id)) else { continue };
        let Some(bytes) = response.filter(|r| (200..300).contains(&r.status_code)).and_then(|r| r.body.clone()) else {
            continue;
        };
        // Not a video after all (a sign-in page, an error page).
        if bytes.len() < 1024 || bytes.starts_with(b"<") {
            continue;
        }
        store(&url, bytes);
    }
}

/// Writes the copy whole (never a half file under its name), then trims the
/// cache to `CAP`.
fn write(path: &std::path::Path, bytes: &[u8]) {
    let Some(dir) = path.parent() else { return };
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let tmp = path.with_extension("part");
    if std::fs::write(&tmp, bytes).is_err() || std::fs::rename(&tmp, path).is_err() {
        let _ = std::fs::remove_file(&tmp);
        return;
    }
    trim(dir, CAP);
}

fn trim(dir: &std::path::Path, cap: u64) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut files: Vec<(std::time::SystemTime, u64, PathBuf)> = entries
        .filter_map(Result::ok)
        .filter_map(|e| {
            let m = e.metadata().ok()?;
            let done = m.is_file() && e.path().extension().is_none_or(|x| x != "part");
            done.then_some(())?;
            Some((m.modified().ok()?, m.len(), e.path()))
        })
        .collect();
    let mut total: u64 = files.iter().map(|f| f.1).sum();
    files.sort_by_key(|f| f.0);
    for (_, len, path) in files {
        if total <= cap {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            total -= len;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expiring_links_and_their_files() {
        let a = "https://cdn.discordapp.com/attachments/1/2/clip.mov?ex=6ac71291&is=6ac5c111&hm=fa57";
        let b = "https://cdn.discordapp.com/attachments/1/2/clip.mov?ex=7000&is=6000&hm=0000";
        assert!(expires(a));
        assert_eq!(path_for(a), path_for(b), "a fresh link finds the same copy");
        assert!(path_for(a).unwrap().to_string_lossy().ends_with(".mov"));
        assert!(expires("https://bucket.s3.amazonaws.com/v.mp4?X-Amz-Expires=600&X-Amz-Signature=ab"));
        assert!(!expires("https://example.com/v.mp4?t=10"));
        assert!(!expires("https://cdn.discordapp.com/emojis/1.png"));
        let blob = format!("https://b.example/{}", "a".repeat(64));
        assert!(!worth_keeping(&blob) && worth_keeping("https://example.com/v.mp4"));
    }

    #[test]
    fn trims_oldest_first() {
        let dir = std::env::temp_dir().join(format!("inferno-cache-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let old = std::time::SystemTime::now() - std::time::Duration::from_secs(60);
        for (name, at) in [("old", old), ("new", std::time::SystemTime::now())] {
            let p = dir.join(name);
            std::fs::write(&p, [0u8; 100]).unwrap();
            std::fs::File::options().append(true).open(&p).unwrap().set_modified(at).unwrap();
        }
        trim(&dir, 150);
        assert!(!dir.join("old").exists() && dir.join("new").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
