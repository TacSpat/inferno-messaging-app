//! Two clients on one relay, end to end: create a server, invite, join,
//! chat, DM, restart.

use std::time::Duration;

use inferno_core::channel::send::Outgoing;
use inferno_core::nostr_sdk::prelude::*;
use inferno_core::session::{ChannelSpec, Session, StartOptions, Update};
use inferno_core::store::{RelaySource, Store};
use tokio::sync::broadcast::Receiver;

async fn session(keys: &Keys, store: Store, relay: &str) -> std::sync::Arc<Session> {
    store.add_relay(relay, RelaySource::User).unwrap();
    Session::start_with(keys.clone(), store, StartOptions { seed_default_relays: false })
        .await
        .unwrap()
}

async fn wait_for(rx: &mut Receiver<Update>, what: &str, pred: impl Fn(&Update) -> bool) -> Update {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match rx.recv().await {
                Ok(u) if pred(&u) => return u,
                Ok(_) => {}
                Err(e) => panic!("updates closed: {e}"),
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {what}"))
}

#[tokio::test(flavor = "multi_thread")]
async fn create_invite_join_chat_dm_and_restart() {
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let dir = tempfile::tempdir().unwrap();
    let owner_keys = Keys::generate();
    let alice_keys = Keys::generate();

    let owner = session(&owner_keys, Store::open_in_memory().unwrap(), &url).await;
    let alice_db = dir.path().join("alice.sqlite3");
    let alice = session(&alice_keys, Store::open(&alice_db).unwrap(), &url).await;
    let mut owner_rx = owner.updates();
    let mut alice_rx = alice.updates();

    let gid = owner.create_server("Test Inferno").await.unwrap();
    let link = owner.create_invite(&gid).await.unwrap();

    assert_eq!(alice.join(&link).await.unwrap(), gid);
    let state = alice.server(&gid).unwrap().unwrap();
    assert_eq!(state.metadata.name, "Test Inferno");
    assert!(state.is_owner(&owner_keys.public_key()));
    assert!(state.is_member(&alice_keys.public_key()));
    let general = state.structure.channels[0].id.clone();

    // The owner sees Alice arrive.
    wait_for(&mut owner_rx, "alice's join", |u| matches!(u, Update::Server(g) if *g == gid)).await;
    assert!(owner.server(&gid).unwrap().unwrap().is_member(&alice_keys.public_key()));

    // Alice talks; the owner's timeline gets it live.
    alice.send(&gid, &general, &Outgoing { content: "hello from alice", ..Default::default() }).await.unwrap();
    wait_for(&mut owner_rx, "alice's message", |u| matches!(u, Update::Channel { gid: g, .. } if *g == gid)).await;
    let tl = owner.timeline(&gid, &general).unwrap();
    assert_eq!(tl.last().unwrap().content.as_deref(), Some("hello from alice"));
    assert_eq!(tl.last().unwrap().author, alice_keys.public_key());

    // And the other way round, plus a DM.
    owner.send(&gid, &general, &Outgoing { content: "welcome", ..Default::default() }).await.unwrap();
    wait_for(&mut alice_rx, "owner's message", |u| matches!(u, Update::Channel { .. })).await;
    owner.send_dm(alice_keys.public_key(), "psst").await.unwrap();
    let dm = wait_for(&mut alice_rx, "the DM", |u| matches!(u, Update::Dm(_))).await;
    let Update::Dm(dm) = dm else { unreachable!() };
    assert_eq!((dm.sender, dm.body.as_str()), (owner_keys.public_key(), "psst"));

    // Restart Alice from her cache: same servers and history, no network fetch needed.
    let before = alice.timeline(&gid, &general).unwrap();
    assert_eq!(before.len(), 2);
    drop(alice_rx);
    drop(alice);
    let alice = Session::start_with(alice_keys.clone(), Store::open(&alice_db).unwrap(), StartOptions { seed_default_relays: false })
        .await
        .unwrap();
    assert_eq!(alice.servers().unwrap(), vec![gid.clone()]);
    let after = alice.timeline(&gid, &general).unwrap();
    assert_eq!(after.iter().map(|m| m.content.clone()).collect::<Vec<_>>(), before.iter().map(|m| m.content.clone()).collect::<Vec<_>>());
}

#[tokio::test(flavor = "multi_thread")]
async fn a_bad_or_revoked_invite_is_refused() {
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let owner_keys = Keys::generate();
    let owner = session(&owner_keys, Store::open_in_memory().unwrap(), &url).await;
    let alice = session(&Keys::generate(), Store::open_in_memory().unwrap(), &url).await;

    let gid = owner.create_server("x").await.unwrap();
    assert!(alice.join("nostr:naddr1nonsense").await.is_err());
    // A well-formed link to a code that was never published.
    let fake = inferno_core::server::invite_link::encode(&gid, "NOPE", &owner_keys.public_key(), &[]).unwrap();
    assert!(alice.join(&fake).await.is_err());
    assert!(alice.servers().unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn encrypted_channel_keys_reach_members_who_join_later() {
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let owner_keys = Keys::generate();
    let alice_keys = Keys::generate();
    let owner = session(&owner_keys, Store::open_in_memory().unwrap(), &url).await;
    let alice = session(&alice_keys, Store::open_in_memory().unwrap(), &url).await;
    let mut alice_rx = alice.updates();

    let gid = owner.create_server("secret club").await.unwrap();
    let everyone = owner.server(&gid).unwrap().unwrap().roles.iter().find(|r| r.is_everyone()).unwrap().id.clone();
    let vault = owner
        .create_channel(&gid, &ChannelSpec { name: "vault".into(), encrypted: true, allowed_roles: vec![everyone], ..Default::default() })
        .await
        .unwrap();
    let state = owner.server(&gid).unwrap().unwrap();
    assert!(state.channel(&vault).unwrap().encrypted);
    owner.send(&gid, &vault, &Outgoing { content: "the code is 1234", ..Default::default() }).await.unwrap();
    assert_eq!(owner.timeline(&gid, &vault).unwrap()[0].content.as_deref(), Some("the code is 1234"));

    // Alice joins after the channel exists; the owner's session sees her
    // join and shares the key, and her session accepts it.
    let link = owner.create_invite(&gid).await.unwrap();
    alice.join(&link).await.unwrap();
    wait_for(&mut alice_rx, "the key share", |u| matches!(u, Update::Channel { channel_id, .. } if *channel_id == vault)).await;

    owner.send(&gid, &vault, &Outgoing { content: "welcome in", ..Default::default() }).await.unwrap();
    wait_for(&mut alice_rx, "the sealed message", |u| matches!(u, Update::Channel { channel_id, .. } if *channel_id == vault)).await;
    let tl = alice.timeline(&gid, &vault).unwrap();
    assert!(tl.iter().any(|m| m.content.as_deref() == Some("welcome in")), "{tl:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn reply_edit_and_pin_reach_the_other_client() {
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let owner_keys = Keys::generate();
    let owner = session(&owner_keys, Store::open_in_memory().unwrap(), &url).await;
    let alice = session(&Keys::generate(), Store::open_in_memory().unwrap(), &url).await;
    let mut alice_rx = alice.updates();

    let gid = owner.create_server("x").await.unwrap();
    let general = owner.server(&gid).unwrap().unwrap().structure.channels[0].id.clone();
    alice.join(&owner.create_invite(&gid).await.unwrap()).await.unwrap();

    let first = owner.send(&gid, &general, &Outgoing { content: "typo hre", ..Default::default() }).await.unwrap();
    owner.send(&gid, &general, &Outgoing { content: "a reply", reply_to: Some(first.id), ..Default::default() }).await.unwrap();
    owner.edit(&gid, &general, first.id, "typo here").await.unwrap();
    let doomed = owner.send(&gid, &general, &Outgoing { content: "delete me", ..Default::default() }).await.unwrap();
    owner.delete_message(&gid, &general, doomed.id).await.unwrap();
    assert!(owner.timeline(&gid, &general).unwrap().iter().all(|m| m.id != doomed.id));
    owner.pin(&gid, &general, first.id, true).await.unwrap();

    // Wait until Alice has all four events.
    for _ in 0..4 {
        wait_for(&mut alice_rx, "channel traffic", |u| matches!(u, Update::Channel { .. })).await;
    }
    let tl = alice.timeline(&gid, &general).unwrap();
    let edited = tl.iter().find(|m| m.id == first.id).unwrap();
    assert_eq!(edited.content.as_deref(), Some("typo here"));
    assert!(edited.edited_at.is_some() && edited.pinned);
    assert_eq!(tl.iter().find(|m| m.content.as_deref() == Some("a reply")).unwrap().reply_to, Some(first.id));
}

#[tokio::test(flavor = "multi_thread")]
async fn a_profile_update_shows_up_for_other_members() {
    use inferno_core::sync::profile::ProfileUpdate;
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let owner_keys = Keys::generate();
    let alice_keys = Keys::generate();
    let owner = session(&owner_keys, Store::open_in_memory().unwrap(), &url).await;
    let alice = session(&alice_keys, Store::open_in_memory().unwrap(), &url).await;
    let mut owner_rx = owner.updates();

    let gid = owner.create_server("x").await.unwrap();
    alice.join(&owner.create_invite(&gid).await.unwrap()).await.unwrap();
    wait_for(&mut owner_rx, "alice's join", |u| matches!(u, Update::Server(g) if *g == gid)).await;

    alice
        .update_profile(&ProfileUpdate {
            name: Some(Some("alice".into())),
            display_name: Some(Some("Alice A.".into())),
            status: Some(Some("building".into())),
            profile_color: Some(Some("#1e3a8a".into())),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(alice.my_profile().unwrap()["display_name"], "Alice A.");

    // The owner sees it through Alice's member event, without a kind 0 fetch.
    for _ in 0..10 {
        let state = owner.server(&gid).unwrap().unwrap();
        if state.members.get(&alice_keys.public_key()).is_some_and(|m| m.profile.display_name == "Alice A.") {
            let m = &state.members[&alice_keys.public_key()];
            assert_eq!(m.profile.status, "building");
            assert_eq!(m.profile.color.as_deref(), Some("#1e3a8a"));
            return;
        }
        let _ = tokio::time::timeout(Duration::from_secs(1), owner_rx.recv()).await;
    }
    panic!("owner never saw Alice's profile");
}

#[tokio::test(flavor = "multi_thread")]
async fn role_limited_encrypted_channel_and_ordering() {
    use inferno_core::server::{order, publish};
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let owner_keys = Keys::generate();
    let owner = session(&owner_keys, Store::open_in_memory().unwrap(), &url).await;
    let alice = session(&Keys::generate(), Store::open_in_memory().unwrap(), &url).await;

    let gid = owner.create_server("x").await.unwrap();
    alice.join(&owner.create_invite(&gid).await.unwrap()).await.unwrap();

    // Admin-only encrypted channel: Alice has no role, so no key, no access.
    let admins = owner
        .create_channel(&gid, &ChannelSpec { name: "admins".into(), encrypted: true, allowed_roles: vec!["r-nobody".into()], ..Default::default() })
        .await
        .unwrap();
    let state = owner.server(&gid).unwrap().unwrap();
    let ch = state.channel(&admins).unwrap();
    assert!(state.can_read(&owner_keys.public_key(), ch));
    assert!(!state.can_read(&alice.keys().public_key(), ch));
    assert!(alice.send(&gid, &admins, &Outgoing { content: "hi", ..Default::default() }).await.is_err());

    // Categories and moves.
    let cat = owner.create_category(&gid, "Projects").await.unwrap();
    let general = state.structure.channels.iter().find(|c| c.name == "general").unwrap().id.clone();
    owner.move_channel(&gid, &general, Some(&cat), 0).await.unwrap();
    let s = owner.server(&gid).unwrap().unwrap().structure;
    assert_eq!(order::in_category(&s, &cat), vec![general.clone()]);
    owner.rename_category(&gid, &cat, "Work").await.unwrap();
    owner.delete_category(&gid, &cat).await.unwrap();
    let s = owner.server(&gid).unwrap().unwrap().structure;
    assert!(s.categories.is_empty());
    assert!(s.channel_is_root(&general));
    let _ = publish::new_public_id();
}

#[tokio::test(flavor = "multi_thread")]
async fn roles_moderation_and_metadata_round_trip() {
    use inferno_core::server::{wire, Permission};
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let owner_keys = Keys::generate();
    let alice_keys = Keys::generate();
    let owner = session(&owner_keys, Store::open_in_memory().unwrap(), &url).await;
    let alice = session(&alice_keys, Store::open_in_memory().unwrap(), &url).await;
    let gid = owner.create_server("x").await.unwrap();
    alice.join(&owner.create_invite(&gid).await.unwrap()).await.unwrap();
    let a = alice_keys.public_key();

    // A moderator role, assigned to Alice.
    let mut roles = owner.server(&gid).unwrap().unwrap().roles.clone();
    roles.push(wire::Role {
        id: "r-mod".into(),
        name: "Mod".into(),
        color: "#22c55e".into(),
        position: 5,
        hoist: true,
        mentionable: false,
        permissions: serde_json::json!({"kick_members": true}).as_object().cloned().unwrap(),
        role_type: String::new(),
    });
    owner.save_roles(&gid, roles).await.unwrap();
    owner.set_member_roles(&gid, &a, &["r-mod".into()]).await.unwrap();
    let state = owner.server(&gid).unwrap().unwrap();
    assert!(state.has(&a, Permission::KickMembers));

    owner.update_metadata(&gid, |m| m.name = "Renamed".into()).await.unwrap();
    assert_eq!(owner.server(&gid).unwrap().unwrap().metadata.name, "Renamed");

    owner.timeout(&gid, &a, inferno_core::store::now_secs() + 600).await.unwrap();
    assert!(owner.server(&gid).unwrap().unwrap().timed_out_until(&a, inferno_core::store::now_secs()).is_some());
    owner.ban(&gid, &a, "test").await.unwrap();
    assert!(owner.server(&gid).unwrap().unwrap().is_banned(&a));
    owner.unban(&gid, &a).await.unwrap();
    assert!(!owner.server(&gid).unwrap().unwrap().is_banned(&a));
}
