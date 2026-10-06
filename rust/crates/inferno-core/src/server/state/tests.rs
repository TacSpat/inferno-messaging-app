//! Fixtures follow the tag layout of `nostr_server_publish_job.rb`.

use nostr::prelude::*;
use serde_json::json;

use super::*;

const GID: &str = "inferno-abc123";

struct T {
    owner: Keys,
    admin: Keys,
    alice: Keys,
    mallory: Keys,
    clock: std::cell::Cell<u64>,
}

impl T {
    fn new() -> Self {
        Self {
            owner: Keys::generate(),
            admin: Keys::generate(),
            alice: Keys::generate(),
            mallory: Keys::generate(),
            clock: std::cell::Cell::new(1_000),
        }
    }

    /// Strictly increasing timestamps, so "later" in a test means newer.
    fn ev(&self, signer: &Keys, kind: u16, tags: Vec<Vec<String>>) -> Event {
        self.clock.set(self.clock.get() + 1);
        EventBuilder::new(Kind::Custom(kind), "")
            .tags(tags.into_iter().map(|t| Tag::parse(t).unwrap()))
            .custom_created_at(Timestamp::from(self.clock.get()))
            .finalize(signer)
            .unwrap()
    }

    fn roles(&self, signer: &Keys) -> Event {
        let admin_perms = json!({ "administrator": true }).to_string();
        let everyone = json!({ "send_messages": true, "read_messages": true, "create_invite": true }).to_string();
        self.ev(signer, kinds::SERVER_ROLES, vec![
            s(&["d", &dtag::roles(GID)]),
            s(&["server", GID]),
            s(&["role", "r-admin", "Admin", "#ff0000", "10", "true", "false", &admin_perms, ""]),
            s(&["role", "r-mod", "Mod", "#00ff00", "5", "true", "false", r#"{"kick_members":true}"#, ""]),
            s(&["role", "r-everyone", "@everyone", "#99aab5", "0", "false", "false", &everyone, ""]),
        ])
    }

    fn member(&self, signer: &Keys, target: &Keys, extra: &[&[&str]]) -> Event {
        let pk = target.public_key().to_hex();
        let mut tags = vec![s(&["d", &dtag::member(GID, &pk)]), s(&["server", GID]), s(&["p", &pk])];
        tags.extend(extra.iter().map(|t| s(t)));
        self.ev(signer, kinds::SERVER_MEMBER, tags)
    }

    fn structure(&self, signer: &Keys, channel_name: &str) -> Event {
        self.ev(signer, kinds::SERVER_STRUCTURE, vec![
            s(&["d", &dtag::structure(GID)]),
            s(&["server", GID]),
            s(&["cat", "c1", "Text", "0"]),
            s(&["ch", "ch1", channel_name, "text", "0", "c1", "topic", "false", "grp-1", "{}",
                "false", "", "", "", "64000", "0", "false", "false"]),
            s(&["ch", "ch2", "announcements", "text", "1", "c1", "", "false", "grp-2", "{}",
                "false", "", "", "", "64000", "0", "false", "true"]),
        ])
    }

    fn ban(&self, signer: &Keys, target: &Keys, unbanned: bool) -> Event {
        let pk = target.public_key().to_hex();
        let mut tags = vec![s(&["d", &dtag::ban(GID, &pk)]), s(&["server", GID]), s(&["p", &pk])];
        if unbanned {
            tags.push(s(&["unbanned", "true"]));
        } else {
            tags.push(s(&["reason", "spam"]));
        }
        self.ev(signer, kinds::SERVER_BAN, tags)
    }

    /// Owner publishes roles and makes `admin` an admin; Alice joins.
    fn base(&self) -> Vec<Event> {
        vec![
            self.roles(&self.owner),
            self.member(&self.owner, &self.admin, &[&["roles", "r-admin"]]),
            self.member(&self.alice, &self.alice, &[&["profile_name", "alice"], &["joined_at", "900"]]),
        ]
    }

    fn resolve(&self, events: &[Event]) -> ServerState {
        ServerState::resolve(GID, self.owner.public_key(), events)
    }
}

fn s(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|p| p.to_string()).collect()
}

#[test]
fn parses_rails_structure_and_roles() {
    let t = T::new();
    let mut events = t.base();
    events.push(t.structure(&t.owner, "general"));
    let state = t.resolve(&events);

    assert_eq!(state.roles.len(), 3);
    assert!(state.roles.iter().any(|r| r.is_everyone()));
    let ch = state.channel("ch1").unwrap();
    assert_eq!((ch.name.as_str(), ch.kind.as_str(), ch.group_id.as_deref()), ("general", "text", Some("grp-1")));
    assert_eq!(ch.voice_bitrate, 64_000);
    assert!(state.channel("ch2").unwrap().post_only);
    assert_eq!(state.channel_by_group("grp-2").unwrap().id, "ch2");
    assert_eq!(state.structure.categories[0].name, "Text");
}

#[test]
fn a_stranger_cannot_define_the_server() {
    let t = T::new();
    let mut events = t.base();
    events.push(t.structure(&t.owner, "general"));
    // Mallory publishes newer structure and roles at the same d-tags.
    events.push(t.structure(&t.mallory, "pwned"));
    events.push(t.roles(&t.mallory));
    let state = t.resolve(&events);
    assert_eq!(state.channel("ch1").unwrap().name, "general");
}

#[test]
fn an_admin_granted_by_the_owner_can_edit_structure() {
    let t = T::new();
    let mut events = t.base();
    events.push(t.structure(&t.owner, "general"));
    events.push(t.structure(&t.admin, "renamed-by-admin"));
    assert_eq!(t.resolve(&events).channel("ch1").unwrap().name, "renamed-by-admin");
}

#[test]
fn members_cannot_grant_themselves_roles() {
    let t = T::new();
    let mut events = t.base();
    events.push(t.member(&t.alice, &t.alice, &[&["roles", "r-admin"]]));
    events.push(t.structure(&t.alice, "alice-was-here"));
    let state = t.resolve(&events);
    assert!(state.members[&t.alice.public_key()].roles.is_empty());
    assert!(!state.has(&t.alice.public_key(), Permission::Administrator));
    assert!(state.structure.channels.is_empty(), "her structure doesn't count");
}

#[test]
fn an_owner_permission_in_a_role_grants_nothing_extra() {
    let t = T::new();
    let mut events = t.base();
    // An admin mints a role with "owner": true and gives it to Mallory.
    let rogue = json!({ "owner": true }).to_string();
    events.push(t.ev(&t.admin, kinds::SERVER_ROLES, vec![
        s(&["d", &dtag::roles(GID)]),
        s(&["server", GID]),
        s(&["role", "r-admin", "Admin", "#f00", "10", "true", "false", r#"{"administrator":true}"#, ""]),
        s(&["role", "r-rogue", "Rogue", "#000", "20", "false", "false", &rogue, ""]),
        s(&["role", "r-everyone", "@everyone", "#99aab5", "0", "false", "false", r#"{"send_messages":true}"#, ""]),
    ]));
    events.push(t.member(&t.mallory, &t.mallory, &[]));
    events.push(t.member(&t.admin, &t.mallory, &[&["roles", "r-rogue"]]));
    let state = t.resolve(&events);
    assert!(!state.has(&t.mallory.public_key(), Permission::ManageServer));
    assert!(!state.is_owner(&t.mallory.public_key()));
}

#[test]
fn bans_hide_members_and_block_rejoining_until_unbanned() {
    let t = T::new();
    let mut events = t.base();
    events.push(t.structure(&t.owner, "general"));
    events.push(t.ban(&t.admin, &t.alice, false));
    events.push(t.member(&t.alice, &t.alice, &[])); // rejoin attempt
    let state = t.resolve(&events);
    let alice = t.alice.public_key();
    assert!(state.is_banned(&alice));
    assert!(!state.is_member(&alice));
    assert_eq!(state.can_send(&alice, state.channel("ch1").unwrap(), 0), Err(SendDenied::Banned));

    events.push(t.ban(&t.owner, &t.alice, true));
    events.push(t.member(&t.alice, &t.alice, &[]));
    let state = t.resolve(&events);
    assert!(!state.is_banned(&alice));
    assert!(state.is_member(&alice));
}

#[test]
fn only_ban_holders_can_ban() {
    let t = T::new();
    let mut events = t.base();
    events.push(t.ban(&t.mallory, &t.alice, false));
    assert!(!t.resolve(&events).is_banned(&t.alice.public_key()));
}

#[test]
fn timeouts_block_sending_until_they_expire() {
    let t = T::new();
    let mut events = t.base();
    events.push(t.structure(&t.owner, "general"));
    let alice = t.alice.public_key();
    events.push(t.member(&t.admin, &t.alice, &[&["timed_out_until", "5000"], &["timed_out_by", &t.admin.public_key().to_hex()]]));
    let state = t.resolve(&events);
    let ch = state.channel("ch1").unwrap();
    assert_eq!(state.can_send(&alice, ch, 4_000), Err(SendDenied::TimedOut { until: 5_000 }));
    assert_eq!(state.can_send(&alice, ch, 5_001), Ok(()));

    // Alice can't lift her own timeout, and a later profile edit keeps it.
    events.push(t.member(&t.alice, &t.alice, &[&["timed_out_until", "0"], &["nickname", "innocent"]]));
    let state = t.resolve(&events);
    assert_eq!(state.timed_out_until(&alice, 4_000), Some(5_000));
    assert_eq!(state.members[&alice].nickname.as_deref(), Some("innocent"));
}

#[test]
fn post_only_channels_need_manage_messages() {
    let t = T::new();
    let mut events = t.base();
    events.push(t.structure(&t.owner, "general"));
    let state = t.resolve(&events);
    let announcements = state.channel("ch2").unwrap();
    assert_eq!(state.can_send(&t.alice.public_key(), announcements, 0), Err(SendDenied::PostOnly));
    assert_eq!(state.can_send(&t.admin.public_key(), announcements, 0), Ok(()));
    assert_eq!(state.can_send(&t.mallory.public_key(), announcements, 0), Err(SendDenied::NotAMember));
}

#[test]
fn leaving_and_being_kicked() {
    let t = T::new();
    let mut events = t.base();
    let alice = t.alice.public_key();
    events.push(t.member(&t.alice, &t.alice, &[&["removed", "true"]]));
    assert!(!t.resolve(&events).is_member(&alice));

    events.push(t.member(&t.alice, &t.alice, &[]));
    assert!(t.resolve(&events).is_member(&alice), "rejoin after leaving");

    events.push(t.member(&t.mallory, &t.alice, &[&["removed", "true"]]));
    assert!(t.resolve(&events).is_member(&alice), "a stranger can't kick");
    events.push(t.member(&t.admin, &t.alice, &[&["removed", "true"]]));
    assert!(!t.resolve(&events).is_member(&alice));
}

#[test]
fn mislabelled_d_tags_are_ignored() {
    let t = T::new();
    let mut events = t.base();
    // A member event whose d-tag names Mallory but whose p-tag names Alice.
    let wrong_d = dtag::member(GID, &t.mallory.public_key().to_hex());
    events.push(t.ev(&t.owner, kinds::SERVER_MEMBER, vec![
        s(&["d", &wrong_d]), s(&["server", GID]), s(&["p", &t.alice.public_key().to_hex()]),
        s(&["removed", "true"]),
    ]));
    assert!(t.resolve(&events).is_member(&t.alice.public_key()));
}

#[test]
fn emoji_stickers_and_invites() {
    let t = T::new();
    let mut events = t.base();
    let creator = t.alice.public_key().to_hex();
    events.push(t.ev(&t.admin, kinds::SERVER_EMOJI, vec![
        s(&["d", &dtag::emojis(GID)]), s(&["server", GID]),
        s(&["emoji", "blaze", "https://blossom.example/abc.png", &creator]),
    ]));
    events.push(t.ev(&t.owner, kinds::SERVER_STICKERS, vec![
        s(&["d", &dtag::stickers(GID)]), s(&["server", GID]),
        s(&["sticker", "wave", "says hi", "https://blossom.example/w.png", &creator]),
    ]));
    // @everyone has create_invite, so Alice may invite; Mallory isn't a member.
    for (who, code) in [(&t.alice, "AAA"), (&t.mallory, "MMM")] {
        events.push(t.ev(who, kinds::SERVER_INVITE, vec![
            s(&["d", &dtag::invite(GID, code)]), s(&["server", GID]), s(&["code", code]),
            s(&["max_uses", "5"]), s(&["expires_at", "0"]), s(&["created_by", &who.public_key().to_hex()]),
        ]));
    }
    let state = t.resolve(&events);
    assert_eq!(state.emojis[0].name, "blaze");
    assert_eq!(state.stickers[0].description, "says hi");
    assert!(state.invites.contains_key("AAA"));
    assert!(!state.invites.contains_key("MMM"));
}

#[test]
fn hoisted_roles_sort_first() {
    let t = T::new();
    let mut events = t.base();
    events.push(t.member(&t.owner, &t.mallory, &[]));
    let state = t.resolve(&events);
    let order: Vec<_> = state.sorted_members().iter().map(|m| m.pubkey).collect();
    assert_eq!(order[0], t.admin.public_key());
}
