use nostr::prelude::*;
use serde_json::json;

use super::*;
use crate::channel::{keys, send};
use crate::channel::send::{Outgoing, SendError};
use crate::dtag;
use crate::server::state::SendDenied;

const GID: &str = "inferno-abc123";

struct World {
    owner: Keys,
    mod_: Keys,
    alice: Keys,
    bob: Keys,
    mallory: Keys,
    state_events: Vec<Event>,
    clock: std::cell::Cell<u64>,
}

fn s(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|p| p.to_string()).collect()
}

impl World {
    fn new(encrypted_pubkey: Option<&str>) -> Self {
        let w = World {
            owner: Keys::generate(),
            mod_: Keys::generate(),
            alice: Keys::generate(),
            bob: Keys::generate(),
            mallory: Keys::generate(),
            state_events: vec![],
            clock: std::cell::Cell::new(1_000),
        };
        let everyone = json!({ "send_messages": true, "read_messages": true, "add_reactions": true }).to_string();
        let mod_perms = json!({ "manage_messages": true, "kick_members": true }).to_string();
        let enc = encrypted_pubkey.is_some().to_string();
        let overrides = if encrypted_pubkey.is_some() { r#"{"allowed_role_ids":["r-everyone"]}"# } else { "{}" };
        let mut events = vec![
            w.ev(&w.owner, crate::kinds::SERVER_ROLES, vec![
                s(&["d", &dtag::roles(GID)]), s(&["server", GID]),
                s(&["role", "r-mod", "Mod", "#0f0", "5", "true", "false", &mod_perms, ""]),
                s(&["role", "r-everyone", "@everyone", "#99aab5", "0", "false", "false", &everyone, ""]),
            ]),
            w.ev(&w.owner, crate::kinds::SERVER_STRUCTURE, vec![
                s(&["d", &dtag::structure(GID)]), s(&["server", GID]),
                s(&["ch", "ch1", "general", "text", "0", "", "", "false", "grp-1", overrides,
                    &enc, encrypted_pubkey.unwrap_or(""), "", "", "64000", "0", "false", "false"]),
            ]),
        ];
        for (who, roles) in [(&w.mod_, Some("r-mod")), (&w.alice, None), (&w.bob, None)] {
            let pk = who.public_key().to_hex();
            let mut tags = vec![s(&["d", &dtag::member(GID, &pk)]), s(&["server", GID]), s(&["p", &pk])];
            if let Some(r) = roles {
                tags.push(s(&["roles", r]));
            }
            events.push(w.ev(&w.owner, crate::kinds::SERVER_MEMBER, tags));
        }
        World { state_events: events, ..w }
    }

    fn ev(&self, signer: &Keys, kind: u16, tags: Vec<Vec<String>>) -> Event {
        self.clock.set(self.clock.get() + 1);
        EventBuilder::new(Kind::Custom(kind), "")
            .tags(tags.into_iter().map(|t| Tag::parse(t).unwrap()))
            .custom_created_at(Timestamp::from(self.clock.get()))
            .finalize(signer)
            .unwrap()
    }

    fn state(&self) -> ServerState {
        ServerState::resolve(GID, self.owner.public_key(), &self.state_events)
    }

    fn channel(&self) -> Channel {
        self.state().channel("ch1").unwrap().clone()
    }

    fn say(&self, who: &Keys, text: &str) -> Event {
        send::message(who, &self.state(), &self.channel(), &Outgoing { content: text, ..Default::default() }, 0).unwrap()
    }

    /// A raw event built by a client that skips our checks.
    fn raw(&self, who: &Keys, kind: u16, content: &str, tags: &[&[&str]]) -> Event {
        let mut all = vec![Tag::parse(["h", "grp-1"]).unwrap()];
        all.extend(tags.iter().map(|t| Tag::parse(t.iter().copied()).unwrap()));
        EventBuilder::new(Kind::Custom(kind), content).tags(all).finalize(who).unwrap()
    }

    fn timeline(&self, events: &[Event]) -> Vec<ChannelMessage> {
        Timeline::resolve(&self.state(), &self.channel(), events, &ChannelKeys::default(), &HashSet::new())
    }
}

#[test]
fn messages_replies_and_reactions() {
    let w = World::new(None);
    let hi = w.say(&w.alice, "hi");
    let state = w.state();
    let reply = send::message(&w.bob, &state, &w.channel(), &Outgoing {
        content: "hey", reply_to: Some(hi.id), ..Default::default()
    }, 0).unwrap();
    let react = |who: &Keys, emoji: &str, at: u64| {
        EventBuilder::new(Kind::Custom(crate::kinds::REACTION), emoji)
            .tags([Tag::parse(["h", "grp-1"]).unwrap(), Tag::event(hi.id)])
            .custom_created_at(Timestamp::from(at))
            .finalize(who)
            .unwrap()
    };

    let mut events = vec![reply, hi.clone(), react(&w.bob, "🔥", 10), react(&w.alice, "🔥", 11), react(&w.bob, "👍", 12)];
    // Both messages land in the same second, so look them up by content.
    let by_text = |tl: &[ChannelMessage], t: &str| tl.iter().find(|m| m.content.as_deref() == Some(t)).unwrap().clone();
    let tl = w.timeline(&events);
    assert_eq!(tl.len(), 2);
    assert_eq!(by_text(&tl, "hey").reply_to, Some(hi.id));
    assert_eq!(by_text(&tl, "hi").reactions["🔥"].len(), 2);
    assert_eq!(by_text(&tl, "hi").reactions["👍"].len(), 1);

    // Bob's "-" clears all of his reactions, nobody else's (Rails' meaning).
    events.push(react(&w.bob, "-", 13));
    let hi_now = by_text(&w.timeline(&events), "hi");
    assert_eq!(hi_now.reactions["🔥"].iter().collect::<Vec<_>>(), [&w.alice.public_key()]);
    assert!(!hi_now.reactions.contains_key("👍"));

    // Our builder refuses reactions from non-members.
    assert!(send::react(&w.mallory, &state, &w.channel(), &hi, "🔥").is_err());
}

#[test]
fn only_authors_edit() {
    let w = World::new(None);
    let hi = w.say(&w.alice, "hi");
    let own = send::edit(&w.alice, &w.state(), &w.channel(), &hi, "hi (fixed)", 0).unwrap();
    // Mallory's client doesn't care about our builder's check.
    let forged = w.raw(&w.mod_, 9, "mod rewrote this", &[&["e", &hi.id.to_hex(), "", "edit"]]);
    assert_eq!(send::edit(&w.bob, &w.state(), &w.channel(), &hi, "nope", 0),
        Err(SendError::Denied(SendDenied::NoPermission)));

    let tl = w.timeline(&[hi, own, forged]);
    assert_eq!(tl.len(), 1);
    assert_eq!(tl[0].content.as_deref(), Some("hi (fixed)"));
    assert!(tl[0].edited_at.is_some());
}

#[test]
fn deletes_need_the_author_or_a_moderator() {
    let w = World::new(None);
    let a = w.say(&w.alice, "a");
    let b = w.say(&w.alice, "b");
    let c = w.say(&w.alice, "c");
    let by_bob = w.raw(&w.bob, 9005, "", &[&["e", &a.id.to_hex()]]);
    let by_self = send::delete(&w.alice, &w.state(), &w.channel(), &b).unwrap();
    let by_mod = send::delete(&w.mod_, &w.state(), &w.channel(), &c).unwrap();
    assert!(send::delete(&w.bob, &w.state(), &w.channel(), &a).is_err());

    let tl = w.timeline(&[a, b, c, by_bob, by_self, by_mod]);
    assert_eq!(tl.iter().map(|m| m.content.as_deref().unwrap()).collect::<Vec<_>>(), ["a"]);
}

#[test]
fn pins_need_manage_messages() {
    let w = World::new(None);
    let a = w.say(&w.alice, "a");
    let by_alice = w.raw(&w.alice, 9006, "", &[&["e", &a.id.to_hex()], &["pinned", "true"]]);
    assert!(!w.timeline(&[a.clone(), by_alice])[0].pinned);
    let by_mod = send::pin(&w.mod_, &w.state(), &w.channel(), a.id, true).unwrap();
    assert!(w.timeline(&[a, by_mod])[0].pinned);
}

#[test]
fn banned_blocked_and_timed_out_senders_vanish() {
    let mut w = World::new(None);
    let from_bob = w.say(&w.bob, "bob here");
    let from_alice = w.say(&w.alice, "alice here");

    let blocked: HashSet<_> = [w.bob.public_key()].into();
    let tl = Timeline::resolve(&w.state(), &w.channel(), &[from_bob.clone(), from_alice.clone()], &ChannelKeys::default(), &blocked);
    assert_eq!(tl.len(), 1, "blocking filters in the core");

    let pk = w.bob.public_key().to_hex();
    w.state_events.push(w.ev(&w.owner, crate::kinds::SERVER_BAN, vec![
        s(&["d", &dtag::ban(GID, &pk)]), s(&["server", GID]), s(&["p", &pk]), s(&["reason", "spam"]),
    ]));
    let tl = w.timeline(&[from_bob, from_alice.clone()]);
    assert_eq!(tl.len(), 1, "a banned user's history disappears");

    // Alice is timed out from t=2000 to t=3000; a message stamped inside
    // that window is dropped even though her client sent it.
    let apk = w.alice.public_key().to_hex();
    w.clock.set(1_999);
    w.state_events.push(w.ev(&w.mod_, crate::kinds::SERVER_MEMBER, vec![
        s(&["d", &dtag::member(GID, &apk)]), s(&["server", GID]), s(&["p", &apk]),
        s(&["timed_out_until", "3000"]),
    ]));
    let during = EventBuilder::new(Kind::Custom(9), "sneaky")
        .tag(Tag::parse(["h", "grp-1"]).unwrap())
        .custom_created_at(Timestamp::from(2_500))
        .finalize(&w.alice)
        .unwrap();
    let tl = w.timeline(&[from_alice, during]);
    assert_eq!(tl.len(), 1);
    assert_eq!(
        send::message(&w.alice, &w.state(), &w.channel(), &Outgoing { content: "x", ..Default::default() }, 2_500),
        Err(SendError::Denied(SendDenied::TimedOut { until: 3_000 }))
    );
}

#[test]
fn encrypted_channel_end_to_end() {
    let channel_key = keys::generate();
    let w = World::new(Some(&channel_key.public_key().to_hex()));
    let state = w.state();

    // The owner shares the key with every reader.
    let shares = keys::share(&w.owner, GID, "ch1", &channel_key, keys::readers(&state, &w.channel())).unwrap();
    assert_eq!(shares.len(), 4, "mod, alice, bob, and the owner");

    let secret = send::message(&w.alice, &state, &w.channel(), &Outgoing { content: "top secret", ..Default::default() }, 0).unwrap();
    assert!(!secret.content.contains("top secret"));

    // Bob unlocks the share addressed to him and reads it.
    let mut bob_keys = ChannelKeys::default();
    let unlocked = shares.iter().find_map(|wrap| bob_keys.accept(&w.bob, &state, wrap));
    assert_eq!(unlocked.as_deref(), Some("ch1"));
    let tl = Timeline::resolve(&state, &w.channel(), std::slice::from_ref(&secret), &bob_keys, &HashSet::new());
    assert_eq!(tl[0].content.as_deref(), Some("top secret"));

    // Without the key the message is there but unreadable.
    let tl = w.timeline(&[secret]);
    assert_eq!(tl[0].content, None);

    // Plaintext in an encrypted channel is dropped.
    let leak = w.raw(&w.alice, 9, "oops plaintext", &[]);
    assert!(w.timeline(&[leak]).is_empty());
}

#[test]
fn refuses_to_send_plaintext_when_the_key_is_missing() {
    // Flutter's bug: encrypted channel created without a key.
    let w = World::new(Some(""));
    let channel = w.channel();
    assert!(channel.encrypted && channel.channel_pubkey.is_none());
    let result = send::message(&w.alice, &w.state(), &channel, &Outgoing { content: "hi", ..Default::default() }, 0);
    assert_eq!(result.unwrap_err(), SendError::MissingChannelKey);
}

#[test]
fn forged_key_shares_are_refused() {
    let real = keys::generate();
    let w = World::new(Some(&real.public_key().to_hex()));
    let state = w.state();

    // A member without manage_channels shares the real key: refused.
    let from_alice = keys::share(&w.alice, GID, "ch1", &real, [w.bob.public_key()]).unwrap();
    // The owner shares a key the channel doesn't announce: refused.
    let wrong = keys::share(&w.owner, GID, "ch1", &keys::generate(), [w.bob.public_key()]).unwrap();
    // A share for another server: refused.
    let elsewhere = keys::share(&w.owner, "inferno-other", "ch1", &real, [w.bob.public_key()]).unwrap();

    let mut bob_keys = ChannelKeys::default();
    for wrap in from_alice.iter().chain(&wrong).chain(&elsewhere) {
        assert_eq!(bob_keys.accept(&w.bob, &state, wrap), None);
    }
    assert!(bob_keys.get(&real.public_key().to_hex()).is_none());
}
