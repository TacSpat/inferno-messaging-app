use nostr::prelude::*;

use super::*;
use crate::{dtag, kinds};

const GID: &str = "inferno-abc";

fn metadata(keys: &Keys, at: u64, name: &str) -> Event {
    EventBuilder::new(Kind::Custom(kinds::SERVER_METADATA), name)
        .tag(Tag::identifier(dtag::metadata(GID)))
        .custom_created_at(Timestamp::from(at))
        .finalize(keys)
        .unwrap()
}

fn chat(keys: &Keys, channel: &str, text: &str) -> Event {
    EventBuilder::new(Kind::Custom(9), text)
        .tag(Tag::parse(["h", channel]).unwrap())
        .finalize(keys)
        .unwrap()
}

fn delete(keys: &Keys, at: u64, ids: &[EventId], coords: &[Coordinate]) -> Event {
    let mut tags: Vec<Tag> = ids.iter().map(|id| Tag::event(*id)).collect();
    tags.extend(coords.iter().map(|c| Tag::coordinate(c.clone(), None)));
    EventBuilder::new(Kind::EventDeletion, "")
        .tags(tags)
        .custom_created_at(Timestamp::from(at))
        .finalize(keys)
        .unwrap()
}

fn metadata_coord(keys: &Keys) -> Coordinate {
    Coordinate::new(Kind::Custom(kinds::SERVER_METADATA), keys.public_key())
        .identifier(dtag::metadata(GID))
}

#[test]
fn migrations_run_once_and_survive_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("cache.sqlite3");
    let keys = Keys::generate();
    {
        let store = Store::open(&path).unwrap();
        store.put_event(&chat(&keys, "general", "hi")).unwrap();
    }
    let store = Store::open(&path).unwrap();
    let version: i64 = store.conn().pragma_query_value(None, "user_version", |r| r.get(0)).unwrap();
    assert_eq!(version as usize, migrations::latest());
    assert_eq!(store.events_by_tag(Kind::Custom(9), 'h', "general", 10).unwrap().len(), 1);
}

#[test]
fn duplicate_and_stale_copies_are_refused() {
    let store = Store::open_in_memory().unwrap();
    let keys = Keys::generate();
    let old = metadata(&keys, 100, "old");
    let new = metadata(&keys, 200, "new");

    assert_eq!(store.put_event(&new).unwrap(), PutOutcome::Inserted);
    assert_eq!(store.put_event(&new).unwrap(), PutOutcome::Duplicate);
    assert_eq!(store.put_event(&old).unwrap(), PutOutcome::Stale);

    let current = store
        .get_addressable(Kind::Custom(kinds::SERVER_METADATA), &keys.public_key(), &dtag::metadata(GID))
        .unwrap()
        .unwrap();
    assert_eq!(current.content, "new");
}

#[test]
fn newer_copy_replaces_and_drops_the_old_tags() {
    let store = Store::open_in_memory().unwrap();
    let keys = Keys::generate();
    store.put_event(&metadata(&keys, 100, "old")).unwrap();
    assert_eq!(store.put_event(&metadata(&keys, 200, "new")).unwrap(), PutOutcome::Inserted);
    let tagged = store
        .events_by_tag(Kind::Custom(kinds::SERVER_METADATA), 'd', &dtag::metadata(GID), 10)
        .unwrap();
    assert_eq!(tagged.len(), 1, "the replaced copy's tag rows are cascaded away");
    assert_eq!(tagged[0].content, "new");
}

#[test]
fn tie_goes_to_the_lowest_id() {
    let store = Store::open_in_memory().unwrap();
    let keys = Keys::generate();
    let a = metadata(&keys, 100, "a");
    let b = metadata(&keys, 100, "b");
    let (low, high) = if a.id < b.id { (a, b) } else { (b, a) };
    store.put_event(&high).unwrap();
    assert_eq!(store.put_event(&low).unwrap(), PutOutcome::Inserted);
    assert_eq!(store.put_event(&high).unwrap(), PutOutcome::Stale);
}

#[test]
fn author_deletion_removes_the_event_for_good() {
    let store = Store::open_in_memory().unwrap();
    let keys = Keys::generate();
    let msg = chat(&keys, "general", "oops");
    store.put_event(&msg).unwrap();
    store.put_event(&delete(&keys, 1_000, &[msg.id], &[])).unwrap();

    assert!(store.get_event(&msg.id).unwrap().is_none());
    assert!(store.is_deleted(&msg.id).unwrap());
    assert_eq!(store.put_event(&msg).unwrap(), PutOutcome::Deleted, "a relay replay can't resurrect it");
}

#[test]
fn someone_elses_deletion_is_ignored() {
    let store = Store::open_in_memory().unwrap();
    let alice = Keys::generate();
    let mallory = Keys::generate();
    let msg = chat(&alice, "general", "mine");

    // Mallory names the id before we've seen it, then again after.
    store.put_event(&delete(&mallory, 1_000, &[msg.id], &[])).unwrap();
    assert_eq!(store.put_event(&msg).unwrap(), PutOutcome::Inserted);
    store.put_event(&delete(&mallory, 1_001, &[msg.id], &[])).unwrap();
    assert!(store.get_event(&msg.id).unwrap().is_some());

    // And she can't delete Alice's server by address either.
    let server = metadata(&alice, 100, "alice's");
    store.put_event(&server).unwrap();
    let forged = Coordinate::new(Kind::Custom(kinds::SERVER_METADATA), alice.public_key())
        .identifier(dtag::metadata(GID));
    store.put_event(&delete(&mallory, 1_002, &[], &[forged])).unwrap();
    assert!(store.get_event(&server.id).unwrap().is_some());
}

#[test]
fn deleted_server_stays_deleted_until_republished() {
    let store = Store::open_in_memory().unwrap();
    let keys = Keys::generate();
    let server = metadata(&keys, 100, "doomed");
    store.put_event(&server).unwrap();
    store.put_event(&delete(&keys, 500, &[], &[metadata_coord(&keys)])).unwrap();

    assert!(store.get_event(&server.id).unwrap().is_none());
    // A lagging relay's older copy, with a different id, is still refused.
    assert_eq!(store.put_event(&metadata(&keys, 300, "lagging")).unwrap(), PutOutcome::Deleted);
    // A copy published after the deletion is a new server state.
    assert_eq!(store.put_event(&metadata(&keys, 600, "reborn")).unwrap(), PutOutcome::Inserted);
}

#[test]
fn a_removed_default_relay_stays_removed() {
    let store = Store::open_in_memory().unwrap();
    store.seed_default_relays().unwrap();
    store.remove_relay("wss://relay.damus.io").unwrap();
    store.seed_default_relays().unwrap();
    assert!(!store.relays().unwrap().iter().any(|r| r.url == "wss://relay.damus.io"));
}

#[test]
fn relay_seeding_only_adds() {
    let store = Store::open_in_memory().unwrap();
    store.seed_default_relays().unwrap();
    store.add_relay("wss://my.relay", RelaySource::User).unwrap();
    store.add_relay("wss://from.other.device", RelaySource::Nip65).unwrap();
    store.seed_default_relays().unwrap();

    let relays = store.relays().unwrap();
    assert_eq!(relays.len(), crate::relay::DEFAULT_RELAYS.len() + 2);
    let mine = relays.iter().find(|r| r.url == "wss://my.relay").unwrap();
    assert_eq!(mine.source, RelaySource::User);

    store.add_relay("wss://my.relay", RelaySource::Default).unwrap();
    let mine = store.relays().unwrap().into_iter().find(|r| r.url == "wss://my.relay").unwrap();
    assert_eq!(mine.source, RelaySource::User, "re-adding keeps the original source");
}

#[test]
fn read_markers_start_unread_and_never_move_back() {
    let store = Store::open_in_memory().unwrap();
    assert_eq!(store.last_read("chan-1").unwrap(), None);
    store.mark_read("chan-1", 200).unwrap();
    store.mark_read("chan-1", 100).unwrap();
    assert_eq!(store.last_read("chan-1").unwrap(), Some(200));
}

#[test]
fn blocks_and_settings() {
    let store = Store::open_in_memory().unwrap();
    store.block("abcd").unwrap();
    store.block("abcd").unwrap();
    assert!(store.is_blocked("abcd").unwrap());
    store.unblock("abcd").unwrap();
    assert!(!store.is_blocked("abcd").unwrap());

    assert_eq!(store.get_setting::<u32>("backfill_days").unwrap(), None);
    store.set_setting("backfill_days", &30u32).unwrap();
    store.set_setting("backfill_days", &14u32).unwrap();
    assert_eq!(store.get_setting::<u32>("backfill_days").unwrap(), Some(14));
}
