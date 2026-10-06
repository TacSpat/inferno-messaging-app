//! NIP-65 relay list (kind 10002): which relays we read from and write to,
//! shared with our other devices and with anyone looking for our events.
//!
//! Flutter only ever added relays from the list, so removing one on a device
//! never reached the others. Here a newer list is authoritative for relays we
//! learned from it: ones it no longer names are dropped. Relays this device
//! added by hand and the defaults are never removed by sync.

use nostr_sdk::prelude::*;

use crate::relay::{normalize_url, RelayPool};
use crate::store::{RelaySource, Store, StoreError};

const LIST_AT: &str = "sync.relay_list_at";

#[derive(Debug, thiserror::Error)]
pub enum RelayListError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Relay(#[from] nostr_sdk::prelude::Error),
    #[error("could not sign the relay list: {0}")]
    Build(String),
    #[error("no relay accepted the relay list")]
    NotPublished,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayEntry {
    pub url: String,
    pub read: bool,
    pub write: bool,
}

pub fn parse(event: &Event) -> Vec<RelayEntry> {
    event
        .tags
        .iter()
        .filter_map(|tag| {
            let t = tag.as_slice();
            if t.first().map(String::as_str) != Some("r") {
                return None;
            }
            let url = normalize_url(t.get(1)?)?;
            let (read, write) = match t.get(2).map(|m| m.to_ascii_lowercase()).as_deref() {
                Some("read") => (true, false),
                Some("write") => (false, true),
                _ => (true, true),
            };
            Some(RelayEntry { url, read, write })
        })
        .collect()
}

pub fn build(keys: &Keys, relays: &[RelayEntry], at: Timestamp) -> Result<Event, RelayListError> {
    let tags = relays.iter().filter(|r| r.read || r.write).map(|r| {
        let mut t = vec!["r".to_owned(), r.url.clone()];
        match (r.read, r.write) {
            (true, false) => t.push("read".into()),
            (false, true) => t.push("write".into()),
            _ => {}
        }
        Tag::parse(t).expect("r tag")
    });
    EventBuilder::new(Kind::RelayList, "")
        .tags(tags)
        .custom_created_at(at)
        .finalize(keys)
        .map_err(|e| RelayListError::Build(e.to_string()))
}

/// Applies a relay list to local state if it's newer than the last one we
/// applied. Returns whether anything was applied.
pub fn apply(store: &Store, event: &Event) -> Result<bool, StoreError> {
    let at = event.created_at.as_secs() as i64;
    if store.get_setting::<i64>(LIST_AT)?.is_some_and(|seen| seen >= at) {
        return Ok(false);
    }
    let listed = parse(event);
    for entry in &listed {
        store.add_relay(&entry.url, RelaySource::Nip65)?;
        store.set_relay_flags(&entry.url, entry.read, entry.write)?;
    }
    for local in store.relays()? {
        if local.source == RelaySource::Nip65 && !listed.iter().any(|e| e.url == local.url) {
            store.remove_relay(&local.url)?;
        }
    }
    store.set_setting(LIST_AT, &at)?;
    Ok(true)
}

async fn fetch_newest(pool: &RelayPool, me: PublicKey) -> Result<Option<Event>, RelayListError> {
    let events = pool.fetch(vec![Filter::new().kind(Kind::RelayList).author(me)]).await?;
    Ok(events.into_iter().max_by_key(|e| e.created_at))
}

/// Applies the newest published list. Call at startup, before connecting
/// to anything the list might add.
pub async fn pull(pool: &RelayPool, store: &Store, keys: &Keys) -> Result<(), RelayListError> {
    if let Some(event) = fetch_newest(pool, keys.public_key()).await? {
        apply(store, &event)?;
    }
    Ok(())
}

/// Publishes this device's relays, after applying anything newer.
pub async fn push(pool: &RelayPool, store: &Store, keys: &Keys) -> Result<(), RelayListError> {
    let newest = fetch_newest(pool, keys.public_key()).await?;
    if let Some(event) = &newest {
        apply(store, event)?;
    }
    let relays: Vec<RelayEntry> = store
        .relays()?
        .into_iter()
        .map(|r| RelayEntry { url: r.url, read: r.read, write: r.write })
        .collect();
    let event = build(keys, &relays, super::publish_time(newest.map(|e| e.created_at)))?;
    if !pool.publish(&event).await?.any_accepted() {
        return Err(RelayListError::NotPublished);
    }
    // We just published it, so it's what we've applied.
    store.set_setting(LIST_AT, &(event.created_at.as_secs() as i64))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn list(keys: &Keys, at: u64, tags: &[&[&str]]) -> Event {
        EventBuilder::new(Kind::RelayList, "")
            .tags(tags.iter().map(|t| Tag::parse(t.iter().copied()).unwrap()))
            .custom_created_at(Timestamp::from(at))
            .finalize(keys)
            .unwrap()
    }

    #[test]
    fn parses_markers_and_skips_junk() {
        let keys = Keys::generate();
        let event = list(&keys, 1, &[
            &["r", "wss://both.example"],
            &["r", "wss://in.example", "read"],
            &["r", "wss://out.example", "WRITE"],
            &["r", "not a url"],
            &["p", "wss://wrong.tag"],
        ]);
        let parsed = parse(&event);
        assert_eq!(parsed.len(), 3);
        assert_eq!((parsed[0].read, parsed[0].write), (true, true));
        assert_eq!((parsed[1].read, parsed[1].write), (true, false));
        assert_eq!((parsed[2].read, parsed[2].write), (false, true));
        assert_eq!(parse(&build(&keys, &parsed, Timestamp::from(2)).unwrap()), parsed, "round trip");
    }

    #[test]
    fn a_newer_list_removes_what_it_dropped_but_never_local_relays() {
        let keys = Keys::generate();
        let store = Store::open_in_memory().unwrap();
        store.seed_default_relays().unwrap();
        store.add_relay("wss://mine.example", RelaySource::User).unwrap();

        assert!(apply(&store, &list(&keys, 100, &[&["r", "wss://a.example"], &["r", "wss://b.example"]])).unwrap());
        assert!(store.relays().unwrap().iter().any(|r| r.url == "wss://b.example"));

        assert!(apply(&store, &list(&keys, 200, &[&["r", "wss://A.example/", "read"]])).unwrap());
        let relays = store.relays().unwrap();
        assert!(!relays.iter().any(|r| r.url == "wss://b.example"), "dropped from the list");
        assert_eq!(relays.iter().filter(|r| r.url == "wss://a.example").count(), 1, "same relay, other spelling");
        let a = relays.iter().find(|r| r.url == "wss://a.example").unwrap();
        assert_eq!((a.read, a.write), (true, false));
        assert!(relays.iter().any(|r| r.url == "wss://mine.example"), "hand-added relay kept");
        assert!(relays.iter().any(|r| r.url == "wss://relay.damus.io"), "defaults kept");

        assert!(!apply(&store, &list(&keys, 150, &[&["r", "wss://b.example"]])).unwrap(), "older list ignored");
        assert!(!store.relays().unwrap().iter().any(|r| r.url == "wss://b.example"));
    }

    #[tokio::test]
    async fn push_publishes_after_the_newest_copy_and_merges_it_first() {
        let relay = MockRelay::run().await.unwrap();
        let url = relay.url().await.to_string();
        let keys = Keys::generate();
        let pool = RelayPool::new(keys.clone());
        pool.add_relays([url.clone()]).await.unwrap();
        pool.connect().await;

        // Another device published a list dated in the future.
        let future = Timestamp::now().as_secs() + 60;
        pool.publish(&list(&keys, future, &[&["r", "wss://other-device.example"]])).await.unwrap();

        let store = Store::open_in_memory().unwrap();
        store.add_relay(&url, RelaySource::User).unwrap();
        push(&pool, &store, &keys).await.unwrap();

        let newest = fetch_newest(&pool, keys.public_key()).await.unwrap().unwrap();
        assert!(newest.created_at.as_secs() > future);
        let urls: Vec<_> = parse(&newest).into_iter().map(|e| e.url).collect();
        assert!(urls.iter().any(|u| u == "wss://other-device.example"));
        assert_eq!(urls.len(), 2);
    }
}
