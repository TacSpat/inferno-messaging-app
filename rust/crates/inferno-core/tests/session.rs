//! Two clients on one relay, end to end: create a server, invite, join,
//! chat, DM, restart.

use std::time::Duration;

use inferno_core::channel::send::Outgoing;
use inferno_core::nostr_sdk::prelude::*;
use inferno_core::social::{Friendship, Payload};
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
    let link = owner.create_invite(&gid, 0, 0).await.unwrap();

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
    owner.send_dm(&alice_keys.public_key(), &Payload::Message { content: "psst".into(), files: vec![], spoiler: false }).await.unwrap();
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
    let link = owner.create_invite(&gid, 0, 0).await.unwrap();
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
    alice.join(&owner.create_invite(&gid, 0, 0).await.unwrap()).await.unwrap();

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
    alice.join(&owner.create_invite(&gid, 0, 0).await.unwrap()).await.unwrap();
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
    alice.join(&owner.create_invite(&gid, 0, 0).await.unwrap()).await.unwrap();

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
    alice.join(&owner.create_invite(&gid, 0, 0).await.unwrap()).await.unwrap();
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

#[tokio::test(flavor = "multi_thread")]
async fn deleting_a_server_removes_it_for_members() {
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let owner = session(&Keys::generate(), Store::open_in_memory().unwrap(), &url).await;
    let alice = session(&Keys::generate(), Store::open_in_memory().unwrap(), &url).await;
    let mut alice_rx = alice.updates();
    let gid = owner.create_server("doomed").await.unwrap();
    alice.join(&owner.create_invite(&gid, 0, 0).await.unwrap()).await.unwrap();
    assert_eq!(alice.servers().unwrap(), vec![gid.clone()]);

    owner.delete_server(&gid).await.unwrap();
    assert!(owner.servers().unwrap().is_empty());
    for _ in 0..10 {
        if alice.servers().unwrap().is_empty() {
            return;
        }
        let _ = tokio::time::timeout(Duration::from_secs(1), alice_rx.recv()).await;
    }
    panic!("alice still lists the deleted server");
}

#[tokio::test(flavor = "multi_thread")]
async fn search_finds_messages_by_text_author_and_channel() {
    use inferno_core::search::Query;
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let owner = session(&Keys::generate(), Store::open_in_memory().unwrap(), &url).await;
    let gid = owner.create_server("x").await.unwrap();
    let general = owner.server(&gid).unwrap().unwrap().structure.channels[0].id.clone();
    let dev = owner.create_channel(&gid, &ChannelSpec { name: "dev".into(), ..Default::default() }).await.unwrap();
    owner.send(&gid, &general, &Outgoing { content: "relay is down again", ..Default::default() }).await.unwrap();
    owner.send(&gid, &dev, &Outgoing { content: "fixed the relay https://example.com/notes.pdf", ..Default::default() }).await.unwrap();
    owner.send(&gid, &dev, &Outgoing { content: "lunch?", ..Default::default() }).await.unwrap();

    let hits = owner.search(&gid, &Query::parse("relay"), 50).unwrap();
    assert_eq!(hits.len(), 2);
    let in_dev = owner.search(&gid, &Query::parse("relay in: dev"), 50).unwrap();
    assert_eq!(in_dev.len(), 1);
    assert_eq!(in_dev[0].channel_name, "dev");
    assert_eq!(owner.search(&gid, &Query::parse("has: file"), 50).unwrap().len(), 1);
    let npub = inferno_core::nostr::nips::nip19::ToBech32::to_bech32(&owner.keys().public_key()).unwrap();
    assert_eq!(owner.search(&gid, &Query::parse(&format!("from: {}", &npub[..12])), 50).unwrap().len(), 3);
}

#[tokio::test(flavor = "multi_thread")]
async fn friends_dms_requests_blocks_and_saved_messages() {
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let (ak, bk, ck) = (Keys::generate(), Keys::generate(), Keys::generate());
    let a = session(&ak, Store::open_in_memory().unwrap(), &url).await;
    let b = session(&bk, Store::open_in_memory().unwrap(), &url).await;
    let c = session(&ck, Store::open_in_memory().unwrap(), &url).await;
    let (apk, bpk, cpk) = (ak.public_key(), bk.public_key(), ck.public_key());
    let msg = |t: &str| Payload::Message { content: t.into(), files: vec![], spoiler: false };
    let mut brx = b.updates();
    let mut arx = a.updates();

    // Friend request, accepted.
    a.add_friend(&bpk).await.unwrap();
    assert_eq!(a.friendship(&bpk).unwrap(), Friendship::Outgoing);
    wait_for(&mut brx, "request", |u| matches!(u, Update::Social)).await;
    assert_eq!(b.friendship(&apk).unwrap(), Friendship::Incoming);
    b.answer_friend(&apk, true).await.unwrap();
    assert_eq!(b.friendship(&apk).unwrap(), Friendship::Accepted);
    wait_for(&mut arx, "accept", |_| a.friendship(&bpk).unwrap() == Friendship::Accepted).await;

    // A conversation between friends, with an edit and a delete.
    let first = a.send_dm(&bpk, &msg("hello")).await.unwrap();
    let second = a.send_dm(&bpk, &msg("oops")).await.unwrap();
    a.send_dm(&bpk, &Payload::Edit { id: first, content: "hello!".into() }).await.unwrap();
    a.send_dm(&bpk, &Payload::Delete { id: second }).await.unwrap();
    wait_for(&mut brx, "edits", |_| b.dm_messages(&apk).unwrap().first().is_some_and(|m| m.edited)).await;
    let seen = b.dm_messages(&apk).unwrap();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].content, "hello!");
    let conv = b.conversations().unwrap();
    assert_eq!(conv.len(), 1);
    assert!(!conv[0].request);
    assert_eq!(conv[0].unread, 1);
    b.mark_dm_read(&apk).unwrap();
    assert_eq!(b.conversations().unwrap()[0].unread, 0);

    // A stranger's message is a request until accepted.
    c.send_dm(&bpk, &msg("buy my stuff")).await.unwrap();
    wait_for(&mut brx, "stranger", |_| b.conversations().unwrap().len() == 2).await;
    let req = b.conversations().unwrap().into_iter().find(|x| x.with == cpk).unwrap();
    assert!(req.request);
    b.accept_dm(&cpk).unwrap();
    assert!(!b.conversations().unwrap().into_iter().find(|x| x.with == cpk).unwrap().request);

    // Blocking hides them, and another device of b's learns it.
    b.block(&cpk).await.unwrap();
    assert!(b.conversations().unwrap().iter().all(|x| x.with != cpk));
    let b2 = session(&bk, Store::open_in_memory().unwrap(), &url).await;
    assert!(b2.blocked_list().unwrap().contains(&cpk));
    let mut b2rx = b2.updates();
    // Friends come back from the DMs alone.
    if b2.friendship(&apk).unwrap() != Friendship::Accepted {
        wait_for(&mut b2rx, "b2 friends", |_| b2.friendship(&apk).unwrap() == Friendship::Accepted).await;
    }
    b.unblock(&cpk).await.unwrap();
    assert!(b.blocked_list().unwrap().is_empty());

    // Saved Messages: a DM to ourselves.
    a.send_dm(&apk, &msg("note to self")).await.unwrap();
    assert!(a.conversations().unwrap().iter().any(|x| x.with == apk && x.preview == "note to self" && !x.request));

    // Removing a friend clears it on both sides.
    a.remove_friend(&bpk).await.unwrap();
    assert_eq!(a.friendship(&bpk).unwrap(), Friendship::None);
    wait_for(&mut brx, "removed", |_| b.friendship(&apk).unwrap() == Friendship::None).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn one_profile_per_person_follows_their_changes() {
    use inferno_core::sync::profile::ProfileUpdate;
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let (ak, bk) = (Keys::generate(), Keys::generate());
    let a = session(&ak, Store::open_in_memory().unwrap(), &url).await;
    let b = session(&bk, Store::open_in_memory().unwrap(), &url).await;
    let gid = a.create_server("x").await.unwrap();
    let link = a.create_invite(&gid, 0, 0).await.unwrap();
    let mut arx = a.updates();
    b.join(&link).await.unwrap();
    wait_for(&mut arx, "b joins", |u| matches!(u, Update::Server(g) if *g == gid)).await;
    // A sees B through the server now; B's later kind 0 must reach A live.
    tokio::time::sleep(Duration::from_millis(800)).await;
    let set = |v: &str| Some(Some(v.to_owned()));
    b.update_profile(&ProfileUpdate {
        name: set("bee"),
        display_name: set("Bee"),
        status: set("on a break"),
        banner: set("https://example.com/banner.png"),
        profile_color: set("#123456"),
        ..Default::default()
    })
    .await
    .unwrap();
    let bpk = bk.public_key();
    wait_for(&mut arx, "b's profile", |u| matches!(u, Update::Profile(p) if *p == bpk)).await;
    let p = a.profile(&bpk).unwrap();
    assert_eq!(p.display_name, "Bee");
    assert_eq!(p.status, "on a break");
    assert_eq!(p.banner.as_deref(), Some("https://example.com/banner.png"));
    assert_eq!(p.color.as_deref(), Some("#123456"));
    assert!(a.known_people().unwrap().contains(&bpk));
}

#[tokio::test(flavor = "multi_thread")]
async fn roles_given_while_offline_arrive_on_restart() {
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let dir = tempfile::tempdir().unwrap();
    let (ak, bk) = (Keys::generate(), Keys::generate());
    let a = session(&ak, Store::open_in_memory().unwrap(), &url).await;
    let b_db = dir.path().join("b.sqlite3");
    let b = session(&bk, Store::open(&b_db).unwrap(), &url).await;
    let gid = a.create_server("x").await.unwrap();
    let link = a.create_invite(&gid, 0, 0).await.unwrap();
    let mut arx = a.updates();
    b.join(&link).await.unwrap();
    wait_for(&mut arx, "b joins", |u| matches!(u, Update::Server(g) if *g == gid)).await;
    // B's cache as it was when B closed. (Dropping the session doesn't stop
    // its background tasks, which would keep writing to the same file.)
    tokio::time::sleep(Duration::from_millis(300)).await;
    let snapshot = dir.path().join("b-closed.sqlite3");
    b.store().snapshot_to(&snapshot).unwrap();
    drop(b);

    // B is away: A makes a role and gives it to B.
    let mut roles = a.server(&gid).unwrap().unwrap().roles;
    roles.push(inferno_core::server::wire::Role {
        id: "mods".into(),
        name: "Mod".into(),
        color: "#22c55e".into(),
        position: 5,
        hoist: true,
        mentionable: true,
        permissions: Default::default(),
        role_type: String::new(),
    });
    a.save_roles(&gid, roles).await.unwrap();
    a.set_member_roles(&gid, &bk.public_key(), &["mods".to_owned()]).await.unwrap();

    // B comes back from that cache and catches up.
    let b = session(&bk, Store::open(&snapshot).unwrap(), &url).await;
    let mut brx = b.updates();
    let has_role = |b: &Session| b.server(&gid).unwrap().unwrap().members.get(&bk.public_key()).is_some_and(|m| m.roles.contains(&"mods".to_owned()));
    if !has_role(&b) {
        wait_for(&mut brx, "catch-up", |_| has_role(&b)).await;
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn invite_uses_limits_and_revocation() {
    let relay = MockRelay::run().await.unwrap();
    let url = relay.url().await.to_string();
    let owner = session(&Keys::generate(), Store::open_in_memory().unwrap(), &url).await;
    let alice_keys = Keys::generate();
    let alice = session(&alice_keys, Store::open_in_memory().unwrap(), &url).await;
    let bob = session(&Keys::generate(), Store::open_in_memory().unwrap(), &url).await;
    let mut owner_rx = owner.updates();

    let gid = owner.create_server("x").await.unwrap();

    // One use: Alice takes it, Bob is turned away.
    let once = owner.create_invite(&gid, 1, 0).await.unwrap();
    assert!(once.contains("naddr1"));
    alice.join(&once).await.unwrap();
    wait_for(&mut owner_rx, "alice's join", |u| matches!(u, Update::Server(g) if *g == gid)).await;
    let state = owner.server(&gid).unwrap().unwrap();
    let code = state.members[&alice_keys.public_key()].invite.clone().unwrap();
    assert_eq!(state.invite_uses(&code), 1);
    assert!(bob.join(&once).await.is_err(), "used up");

    // Expired and revoked invites don't let anyone in either.
    let expired = owner.create_invite(&gid, 0, 1).await.unwrap();
    assert!(bob.join(&expired).await.is_err(), "expired");
    let open = owner.create_invite(&gid, 0, 0).await.unwrap();
    let open_code = owner
        .server(&gid)
        .unwrap()
        .unwrap()
        .invites
        .keys()
        .find(|c| owner.invite_link(&gid, c).as_deref() == Some(open.as_str()))
        .cloned()
        .unwrap();
    owner.revoke_invite(&gid, &open_code).await.unwrap();
    assert!(!owner.server(&gid).unwrap().unwrap().invites.contains_key(&open_code));
    assert!(bob.join(&open).await.is_err(), "revoked");

    // Alice keeps her invite on record through a profile refresh.
    alice.update_profile(&Default::default()).await.unwrap();
    let state = alice.server(&gid).unwrap().unwrap();
    assert_eq!(state.members[&alice_keys.public_key()].invite.as_deref(), Some(code.as_str()));
}
