//! Builders for server-state events, the inverse of [`super::wire`], in the
//! exact tag layout Rails publishes. Each checks the signer's permission in
//! the current state first, since receivers ignore unauthorized copies.

use nostr::prelude::*;
use rand::distr::{Alphanumeric, SampleString};

use super::auth::Permission;
use super::state::ServerState;
use super::wire::{Channel, Metadata, Role, Structure};
use crate::{dtag, kinds};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum PublishError {
    #[error("you don't have permission to do that")]
    NotAllowed,
    #[error("could not sign: {0}")]
    Build(String),
}

/// Rails' `public_id`: 12 random alphanumerics.
pub fn new_public_id() -> String {
    Alphanumeric.sample_string(&mut rand::rng(), 12)
}

/// A new server's gid, as Rails forms it: `inferno-{public_id}`.
pub fn new_gid() -> String {
    format!("inferno-{}", new_public_id())
}

/// A channel's `h` group id, as Rails forms it: `{server_public_id}-{channel_public_id}`.
pub fn channel_group_id(gid: &str, channel_id: &str) -> String {
    format!("{}-{channel_id}", gid.strip_prefix("inferno-").unwrap_or(gid))
}

fn t(parts: &[&str]) -> Tag {
    Tag::parse(parts.iter().copied()).expect("tag")
}

fn sign(keys: &Keys, kind: u16, tags: Vec<Tag>) -> Result<Event, PublishError> {
    EventBuilder::new(Kind::Custom(kind), "")
        .tags(tags)
        .finalize(keys)
        .map_err(|e| PublishError::Build(e.to_string()))
}

fn allowed(keys: &Keys, state: &ServerState, p: Permission) -> Result<(), PublishError> {
    if state.has(&keys.public_key(), p) { Ok(()) } else { Err(PublishError::NotAllowed) }
}

fn b(v: bool) -> &'static str {
    if v { "true" } else { "false" }
}

pub fn metadata(keys: &Keys, state: &ServerState, m: &Metadata) -> Result<Event, PublishError> {
    allowed(keys, state, Permission::ManageServer)?;
    let gid = &state.gid;
    let mut tags = vec![Tag::identifier(dtag::metadata(gid)), t(&["name", &m.name]), t(&["about", &m.about])];
    if let Some(owner) = state.owner {
        tags.push(t(&["owner", &owner.to_hex()]));
    }
    if let Some(p) = &m.picture {
        tags.push(t(&["picture", p]));
    }
    if let Some(p) = &m.banner {
        tags.push(t(&["banner", p]));
    }
    tags.extend(m.relays.iter().map(|r| t(&["relay", r])));
    if let Some(c) = &m.welcome_channel {
        tags.push(t(&["welcome_channel", c]));
    }
    tags.push(t(&["welcome_message", &m.welcome_message]));
    tags.push(t(&["welcome_enabled", b(m.welcome_enabled)]));
    tags.push(t(&["voice_enabled", b(m.voice_enabled)]));
    tags.push(t(&["discoverable", b(m.discoverable)]));
    tags.push(t(&["server_type", &m.server_type]));
    tags.push(t(&["age_restricted", b(m.age_restricted)]));
    if let Some(c) = &m.afk_channel {
        tags.push(t(&["afk_channel", c]));
    }
    tags.push(t(&["afk_timeout", &m.afk_timeout_mins.to_string()]));
    tags.push(t(&["afk_action", &m.afk_action]));
    tags.extend(m.voice_providers.iter().map(|p| t(&["voice_provider", &p.to_hex()])));
    if m.deleted {
        tags.push(t(&["deleted", "true"]));
    }
    sign(keys, kinds::SERVER_METADATA, tags)
}

pub fn structure(keys: &Keys, state: &ServerState, s: &Structure) -> Result<Event, PublishError> {
    allowed(keys, state, Permission::ManageChannels)?;
    let gid = &state.gid;
    let mut tags = vec![Tag::identifier(dtag::structure(gid)), t(&["server", gid])];
    for c in &s.categories {
        tags.push(t(&["cat", &c.id, &c.name, &c.position.to_string()]));
    }
    for c in &s.channels {
        tags.push(channel_row(c));
    }
    sign(keys, kinds::SERVER_STRUCTURE, tags)
}

fn channel_row(c: &Channel) -> Tag {
    let overrides = serde_json::Value::Object(c.permission_overrides.clone()).to_string();
    t(&[
        "ch",
        &c.id,
        &c.name,
        &c.kind,
        &c.position.to_string(),
        c.category.as_deref().unwrap_or(""),
        &c.topic,
        b(c.nsfw),
        c.group_id.as_deref().unwrap_or(""),
        &overrides,
        b(c.encrypted),
        c.channel_pubkey.as_deref().unwrap_or(""),
        c.sidechat.as_deref().unwrap_or(""),
        c.parent.as_deref().unwrap_or(""),
        &c.voice_bitrate.to_string(),
        &c.voice_user_limit.to_string(),
        b(c.video_enabled),
        b(c.post_only),
    ])
}

pub fn roles(keys: &Keys, state: &ServerState, roles: &[Role]) -> Result<Event, PublishError> {
    allowed(keys, state, Permission::ManageRoles)?;
    let gid = &state.gid;
    let mut tags = vec![Tag::identifier(dtag::roles(gid)), t(&["server", gid])];
    for r in roles {
        let perms = serde_json::Value::Object(r.permissions.clone()).to_string();
        tags.push(t(&[
            "role", &r.id, &r.name, &r.color, &r.position.to_string(), b(r.hoist), b(r.mentionable), &perms, &r.role_type,
        ]));
    }
    sign(keys, kinds::SERVER_ROLES, tags)
}

fn member_base(gid: &str, target: &PublicKey) -> Vec<Tag> {
    let pk = target.to_hex();
    vec![Tag::identifier(dtag::member(gid, &pk)), t(&["server", gid]), t(&["p", &pk])]
}

/// Our own join or profile refresh. Rails embeds the profile in member
/// events (so members needn't fetch each other's kind 0), with these tags.
/// No `roles` tag: receivers ignore roles from self-signed events anyway.
pub fn join(
    keys: &Keys,
    gid: &str,
    nickname: &str,
    profile: &super::wire::MemberProfile,
    joined_at: i64,
    invite: Option<&str>,
) -> Result<Event, PublishError> {
    let mut tags = member_base(gid, &keys.public_key());
    tags.push(t(&["nickname", nickname]));
    tags.push(t(&["joined_at", &joined_at.to_string()]));
    // Ours: which invite brought us in, so its uses can be counted.
    if let Some(code) = invite {
        tags.push(t(&["invite", code]));
    }
    let opt = |v: &Option<String>| v.clone().unwrap_or_default();
    for (k, v) in [
        ("profile_name", profile.name.clone()),
        ("profile_display_name", profile.display_name.clone()),
        ("profile_about", profile.about.clone()),
        ("profile_color", opt(&profile.color)),
        ("profile_color_2", opt(&profile.color_2)),
        ("profile_status", profile.status.clone()),
        ("profile_status_emoji", profile.status_emoji.clone()),
        ("profile_picture", opt(&profile.picture)),
        ("profile_banner", opt(&profile.banner)),
    ] {
        tags.push(t(&[k, &v]));
    }
    sign(keys, kinds::SERVER_MEMBER, tags)
}

pub fn leave(keys: &Keys, gid: &str) -> Result<Event, PublishError> {
    let mut tags = member_base(gid, &keys.public_key());
    tags.push(t(&["removed", "true"]));
    sign(keys, kinds::SERVER_MEMBER, tags)
}

/// Sets `target`'s roles (needs `manage_roles`). Carries the member's
/// current nickname so it isn't lost.
pub fn set_roles(keys: &Keys, state: &ServerState, target: &PublicKey, role_ids: &[String]) -> Result<Event, PublishError> {
    allowed(keys, state, Permission::ManageRoles)?;
    let mut tags = member_base(&state.gid, target);
    let mut roles = vec!["roles".to_owned()];
    roles.extend(role_ids.iter().cloned());
    tags.push(Tag::parse(roles).expect("tag"));
    // Ours, for the audit log: which change this event is.
    tags.push(t(&["action", "roles"]));
    carry_member_state(keys, state, target, &mut tags, false, true);
    sign(keys, kinds::SERVER_MEMBER, tags)
}

/// A moderator's member events for one person share one address, so each
/// replaces the last: a timeout must restate their roles and a role change
/// their timeout, or one silently undoes the other. Each part is restated
/// only by someone whose word on it counts.
fn carry_member_state(keys: &Keys, state: &ServerState, target: &PublicKey, tags: &mut Vec<Tag>, roles: bool, timeout: bool) {
    let me = keys.public_key();
    let Some(m) = state.members.get(target) else { return };
    tags.push(t(&["nickname", m.nickname.as_deref().unwrap_or("")]));
    if roles && state.has(&me, Permission::ManageRoles) {
        let mut row = vec!["roles".to_owned()];
        row.extend(m.roles.iter().cloned());
        tags.push(Tag::parse(row).expect("tag"));
    }
    if timeout && (state.has(&me, Permission::KickMembers) || state.has(&me, Permission::ManageRoles)) {
        if let Some(until) = m.timed_out_until.filter(|&u| u > crate::store::now_secs()) {
            tags.push(t(&["timed_out_until", &until.to_string()]));
            tags.push(t(&["timed_out_by", &me.to_hex()]));
        }
    }
}

pub fn kick(keys: &Keys, state: &ServerState, target: &PublicKey) -> Result<Event, PublishError> {
    allowed(keys, state, Permission::KickMembers)?;
    let mut tags = member_base(&state.gid, target);
    tags.push(t(&["removed", "true"]));
    sign(keys, kinds::SERVER_MEMBER, tags)
}

/// `until` = 0 lifts the timeout.
pub fn timeout(keys: &Keys, state: &ServerState, target: &PublicKey, until: i64) -> Result<Event, PublishError> {
    allowed(keys, state, Permission::KickMembers)?;
    let mut tags = member_base(&state.gid, target);
    tags.push(t(&["timed_out_until", &until.to_string()]));
    tags.push(t(&["timed_out_by", &keys.public_key().to_hex()]));
    tags.push(t(&["action", "timeout"]));
    carry_member_state(keys, state, target, &mut tags, true, false);
    sign(keys, kinds::SERVER_MEMBER, tags)
}

pub fn ban(keys: &Keys, state: &ServerState, target: &PublicKey, reason: &str) -> Result<Event, PublishError> {
    allowed(keys, state, Permission::BanMembers)?;
    let pk = target.to_hex();
    let tags = vec![
        Tag::identifier(dtag::ban(&state.gid, &pk)),
        t(&["server", &state.gid]),
        t(&["p", &pk]),
        t(&["reason", reason]),
        t(&["banned_by", &keys.public_key().to_hex()]),
    ];
    sign(keys, kinds::SERVER_BAN, tags)
}

pub fn unban(keys: &Keys, state: &ServerState, target: &PublicKey) -> Result<Event, PublishError> {
    allowed(keys, state, Permission::BanMembers)?;
    let pk = target.to_hex();
    let tags = vec![
        Tag::identifier(dtag::ban(&state.gid, &pk)),
        t(&["server", &state.gid]),
        t(&["p", &pk]),
        t(&["unbanned", "true"]),
    ];
    sign(keys, kinds::SERVER_BAN, tags)
}

pub fn invite(keys: &Keys, state: &ServerState, code: &str, max_uses: u32, expires_at: i64) -> Result<Event, PublishError> {
    allowed(keys, state, Permission::CreateInvite)?;
    let tags = vec![
        Tag::identifier(dtag::invite(&state.gid, code)),
        t(&["server", &state.gid]),
        t(&["code", code]),
        t(&["max_uses", &max_uses.to_string()]),
        t(&["expires_at", &expires_at.to_string()]),
        t(&["created_by", &keys.public_key().to_hex()]),
        t(&["uses", "0"]),
    ];
    sign(keys, kinds::SERVER_INVITE, tags)
}

/// Revokes an invite with Rails' tags (d, server, code, revoked).
pub fn revoke_invite(keys: &Keys, state: &ServerState, code: &str) -> Result<Event, PublishError> {
    let invite = state.invites.get(code).ok_or(PublishError::NotAllowed)?;
    if !state.may_revoke(&keys.public_key(), invite) {
        return Err(PublishError::NotAllowed);
    }
    let tags = vec![
        Tag::identifier(dtag::invite(&state.gid, code)),
        t(&["server", &state.gid]),
        t(&["code", code]),
        t(&["revoked", "true"]),
    ];
    sign(keys, kinds::SERVER_INVITE, tags)
}

/// A new server: the owner's metadata, roles (`@everyone` with Rails'
/// defaults) and structure with one text channel. Publish all three.
pub fn create_server(keys: &Keys, name: &str) -> Result<(String, Vec<Event>), PublishError> {
    let gid = new_gid();
    let state = ServerState { gid: gid.clone(), owner: Some(keys.public_key()), ..Default::default() };
    let everyone = Role {
        id: new_public_id(),
        name: "@everyone".into(),
        color: "#99aab5".into(),
        position: 0,
        hoist: false,
        mentionable: false,
        permissions: serde_json::json!({
            "send_messages": true, "read_messages": true, "read_message_history": true,
            "attach_files": true, "send_gifs": true, "send_custom_emojis": true,
            "send_custom_stickers": true, "add_reactions": true, "change_nickname": true,
            "create_invite": true, "connect_voice": true, "speak": true, "video": true,
            "screen_share": true
        })
        .as_object()
        .cloned()
        .unwrap_or_default(),
        role_type: String::new(),
    };
    let channel_id = new_public_id();
    let general = Channel {
        group_id: Some(channel_group_id(&gid, &channel_id)),
        id: channel_id,
        name: "general".into(),
        kind: "text".into(),
        position: 0,
        category: None,
        topic: String::new(),
        nsfw: false,
        permission_overrides: Default::default(),
        encrypted: false,
        channel_pubkey: None,
        sidechat: None,
        parent: None,
        voice_bitrate: 64_000,
        voice_user_limit: 0,
        video_enabled: false,
        post_only: false,
    };
    let meta = Metadata { name: name.into(), server_type: "community".into(), afk_timeout_mins: 5, afk_action: "move".into(), ..Default::default() };
    let events = vec![
        metadata(keys, &state, &meta)?,
        roles(keys, &state, &[everyone])?,
        structure(keys, &state, &Structure { categories: vec![], channels: vec![general] })?,
    ];
    Ok((gid, events))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::wire;

    #[test]
    fn role_and_timeout_events_dont_undo_each_other() {
        // Relays keep one event per (author, d-tag), and a moderator's role
        // change and timeout for a member share that address.
        let owner = Keys::generate();
        let alice = Keys::generate();
        let (gid, mut events) = create_server(&owner, "x").unwrap();
        let profile = wire::MemberProfile { name: "alice".into(), ..Default::default() };
        events.push(join(&alice, &gid, "", &profile, 0, None).unwrap());
        let mut state = ServerState::resolve(&gid, owner.public_key(), &events);
        let role = state.roles[0].id.clone();
        let until = crate::store::now_secs() + 600;
        let stamp = |e: Event, at: u64| -> Event {
            let b = EventBuilder::new(e.kind, e.content.clone()).tags(e.tags.to_vec()).custom_created_at(Timestamp::from(at));
            b.finalize(&owner).unwrap()
        };
        let base = crate::store::now_secs() as u64;
        events.push(stamp(set_roles(&owner, &state, &alice.public_key(), &[role.clone()]).unwrap(), base + 1));
        events = crate::relay::latest_per_address(events);
        state = ServerState::resolve(&gid, owner.public_key(), &events);
        events.push(stamp(timeout(&owner, &state, &alice.public_key(), until).unwrap(), base + 2));
        events = crate::relay::latest_per_address(events);
        state = ServerState::resolve(&gid, owner.public_key(), &events);
        let m = &state.members[&alice.public_key()];
        assert_eq!(m.roles, vec![role.clone()], "the timeout kept her role");
        assert_eq!(m.timed_out_until, Some(until));
        assert_eq!(m.profile.name, "alice", "a moderator's event doesn't blank her profile");

        // And taking the role away keeps the timeout.
        events.push(stamp(set_roles(&owner, &state, &alice.public_key(), &[]).unwrap(), base + 3));
        events = crate::relay::latest_per_address(events);
        state = ServerState::resolve(&gid, owner.public_key(), &events);
        let m = &state.members[&alice.public_key()];
        assert!(m.roles.is_empty());
        assert_eq!(m.timed_out_until, Some(until));
    }

    #[test]
    fn builders_round_trip_through_the_parsers() {
        let owner = Keys::generate();
        let (gid, events) = create_server(&owner, "Tac's Inferno").unwrap();
        assert!(gid.starts_with("inferno-") && gid.len() == "inferno-".len() + 12);
        let state = ServerState::resolve(&gid, owner.public_key(), &events);
        assert_eq!(state.metadata.name, "Tac's Inferno");
        assert_eq!(state.metadata.owner, Some(owner.public_key()));
        let general = &state.structure.channels[0];
        assert_eq!(general.group_id.as_deref(), Some(channel_group_id(&gid, &general.id).as_str()));
        assert!(state.roles[0].is_everyone());

        // Re-publish the parsed structure: identical tags.
        let again = structure(&owner, &state, &state.structure).unwrap();
        let rows = |e: &Event| e.tags.iter().map(|t| t.as_slice().to_vec()).collect::<Vec<_>>();
        assert_eq!(rows(&again), rows(&events[2]));
        assert_eq!(wire::structure(&again), state.structure);
    }

    #[test]
    fn moderation_builders_check_permission() {
        let owner = Keys::generate();
        let alice = Keys::generate();
        let (gid, mut events) = create_server(&owner, "x").unwrap();
        let profile = crate::server::wire::MemberProfile { name: "alice".into(), ..Default::default() };
        events.push(join(&alice, &gid, "", &profile, 0, None).unwrap());
        let state = ServerState::resolve(&gid, owner.public_key(), &events);
        assert!(state.is_member(&alice.public_key()));
        assert_eq!(ban(&alice, &state, &owner.public_key(), "").unwrap_err(), PublishError::NotAllowed);
        events.push(ban(&owner, &state, &alice.public_key(), "spam").unwrap());
        assert!(ServerState::resolve(&gid, owner.public_key(), &events).is_banned(&alice.public_key()));
    }
}
