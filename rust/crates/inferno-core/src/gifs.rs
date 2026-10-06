//! GIF favorites and collections (Rails' `/api/gif_favorites` and
//! `/api/gif_collections`), kept in the synced config so they follow the
//! user across devices and work without a GIF search service.
//!
//! Each favorite and collection is its own synced key, so two devices
//! editing different ones never overwrite each other; removals stay as
//! tombstones so an older copy elsewhere can't bring them back.

use serde::{Deserialize, Serialize};

use crate::store::{Store, StoreError};

const FAV: &str = "gif_fav:";
const COL: &str = "gif_col:";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Gif {
    /// What gets sent and played.
    pub url: String,
    /// A small version for the picker grid (Tenor's tinygif); `url` if none.
    #[serde(default)]
    pub preview: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Collection {
    pub id: String,
    pub name: String,
    pub gifs: Vec<Gif>,
}

#[derive(Serialize, Deserialize)]
struct FavRecord {
    gif: Gif,
    on: bool,
}

#[derive(Serialize, Deserialize)]
struct ColRecord {
    name: String,
    gifs: Vec<Gif>,
    #[serde(default)]
    deleted: bool,
}

fn key_for(url: &str) -> String {
    format!("{FAV}{}", &crate::blossom::sha256_hex(url.as_bytes())[..16])
}

/// Favorites, newest first.
pub fn favorites(store: &Store) -> Result<Vec<Gif>, StoreError> {
    let mut v: Vec<(i64, Gif)> = store
        .synced_settings_with_prefix(FAV)?
        .into_iter()
        .filter_map(|(_, value, at)| serde_json::from_value::<FavRecord>(value).ok().filter(|r| r.on).map(|r| (at, r.gif)))
        .collect();
    v.sort_by_key(|(at, _)| std::cmp::Reverse(*at));
    Ok(v.into_iter().map(|(_, g)| g).collect())
}

pub fn is_favorite(store: &Store, url: &str) -> Result<bool, StoreError> {
    Ok(store
        .synced_setting(&key_for(url))?
        .and_then(|v| serde_json::from_value::<FavRecord>(v).ok())
        .is_some_and(|r| r.on))
}

/// Rails' fire button: favorite or unfavorite. Returns the new state.
pub fn toggle_favorite(store: &Store, gif: Gif) -> Result<bool, StoreError> {
    let on = !is_favorite(store, &gif.url)?;
    let gif = Gif { preview: if gif.preview.is_empty() { gif.url.clone() } else { gif.preview }, ..gif };
    let record = serde_json::to_value(FavRecord { gif: gif.clone(), on }).expect("serializable");
    store.set_synced_setting(&key_for(&gif.url), record)?;
    Ok(on)
}

pub fn collections(store: &Store) -> Result<Vec<Collection>, StoreError> {
    let mut v: Vec<(i64, Collection)> = store
        .synced_settings_with_prefix(COL)?
        .into_iter()
        .filter_map(|(key, value, at)| {
            let r = serde_json::from_value::<ColRecord>(value).ok().filter(|r| !r.deleted)?;
            Some((at, Collection { id: key[COL.len()..].to_owned(), name: r.name, gifs: r.gifs }))
        })
        .collect();
    v.sort_by(|a, b| a.1.name.to_lowercase().cmp(&b.1.name.to_lowercase()).then(b.0.cmp(&a.0)));
    Ok(v.into_iter().map(|(_, c)| c).collect())
}

fn save(store: &Store, id: &str, r: &ColRecord) -> Result<(), StoreError> {
    store.set_synced_setting(&format!("{COL}{id}"), serde_json::to_value(r).expect("serializable"))
}

fn load(store: &Store, id: &str) -> Result<Option<ColRecord>, StoreError> {
    Ok(store
        .synced_setting(&format!("{COL}{id}"))?
        .and_then(|v| serde_json::from_value::<ColRecord>(v).ok())
        .filter(|r| !r.deleted))
}

pub fn create_collection(store: &Store, name: &str) -> Result<String, StoreError> {
    let id = crate::blossom::sha256_hex(format!("{name}{}", crate::store::now_secs()).as_bytes())[..12].to_owned();
    save(store, &id, &ColRecord { name: name.trim().to_owned(), gifs: vec![], deleted: false })?;
    Ok(id)
}

/// Adds or removes a GIF from a collection.
pub fn toggle_in_collection(store: &Store, id: &str, gif: Gif) -> Result<bool, StoreError> {
    let Some(mut r) = load(store, id)? else { return Ok(false) };
    let present = r.gifs.iter().any(|g| g.url == gif.url);
    if present {
        r.gifs.retain(|g| g.url != gif.url);
    } else {
        r.gifs.insert(0, gif);
    }
    save(store, id, &r)?;
    Ok(!present)
}

pub fn delete_collection(store: &Store, id: &str) -> Result<(), StoreError> {
    if let Some(mut r) = load(store, id)? {
        r.deleted = true;
        r.gifs.clear();
        save(store, id, &r)?;
    }
    Ok(())
}

/// Whether `url` looks like a GIF we can show and send as one.
pub fn looks_like_gif(url: &str) -> bool {
    let path = url.split(['?', '#']).next().unwrap_or(url).to_lowercase();
    (url.starts_with("https://") || url.starts_with("http://"))
        && (path.ends_with(".gif") || path.ends_with(".webp") || path.contains("media.tenor.com") || path.contains("giphy.com/media"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn favorites_toggle_and_order() {
        let s = Store::open_in_memory().unwrap();
        let g = |u: &str| Gif { url: u.into(), preview: String::new() };
        assert!(toggle_favorite(&s, g("https://x/a.gif")).unwrap());
        assert!(toggle_favorite(&s, g("https://x/b.gif")).unwrap());
        assert_eq!(favorites(&s).unwrap().len(), 2);
        assert!(!toggle_favorite(&s, g("https://x/a.gif")).unwrap(), "second press unfavorites");
        let f = favorites(&s).unwrap();
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].preview, "https://x/b.gif", "preview falls back to the GIF");
    }

    #[test]
    fn collections_add_remove_delete() {
        let s = Store::open_in_memory().unwrap();
        let id = create_collection(&s, "  Reactions ").unwrap();
        let gif = Gif { url: "https://x/a.gif".into(), preview: String::new() };
        assert!(toggle_in_collection(&s, &id, gif.clone()).unwrap());
        assert_eq!(collections(&s).unwrap()[0].name, "Reactions");
        assert_eq!(collections(&s).unwrap()[0].gifs.len(), 1);
        assert!(!toggle_in_collection(&s, &id, gif).unwrap());
        delete_collection(&s, &id).unwrap();
        assert!(collections(&s).unwrap().is_empty());
    }

    #[test]
    fn gif_urls() {
        assert!(looks_like_gif("https://media.tenor.com/abc/x.gif?y=1"));
        assert!(looks_like_gif("https://example.com/cat.GIF"));
        assert!(!looks_like_gif("https://example.com/cat.png"));
        assert!(!looks_like_gif("ftp://example.com/cat.gif"));
    }
}
