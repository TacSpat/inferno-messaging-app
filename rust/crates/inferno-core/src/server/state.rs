//! A server's effective state, resolved from its stored events.
//!
//! Every server-state kind is addressable per signer, so the owner and each
//! admin can each have their own copy of, say, the structure. The effective
//! value is the newest copy from a signer allowed to publish it. Allowed
//! depends on roles, and roles come from events, so resolution repeats until
//! permissions stop changing.
//!
//! The owner is pinned when the server is joined (from the invite) and never
//! taken from event content: Rails trusted any signer during its initial sync,
//! so whoever published first could define the server.
//!
//! Enforcement lives here, not in the UI: banned members are gone, timed-out
//! members can't send, and the checks are what the send path consults.

use std::collections::{BTreeMap, HashMap, HashSet};

use nostr::prelude::*;

use super::auth::{grants, required_for, Permission};
use super::wire::{self, Channel, Emoji, Metadata, MemberProfile, Role, Sticker, Structure};
use crate::{dtag, kinds};

#[derive(Debug, Clone, PartialEq)]
pub struct Member {
    pub pubkey: PublicKey,
    pub roles: Vec<String>,
    pub nickname: Option<String>,
    pub joined_at: Option<i64>,
    pub profile: MemberProfile,
    /// Unix seconds; in the past or `None` means not timed out.
    pub timed_out_until: Option<i64>,
    /// When the current timeout was issued, so receivers can drop messages
    /// sent during it.
    pub timed_out_since: Option<i64>,
    /// The invite they joined with, as they said so themselves.
    pub invite: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Ban {
    pub reason: String,
    pub banned_by: Option<PublicKey>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Invite {
    pub code: String,
    pub max_uses: u32,
    pub expires_at: i64,
    pub created_by: PublicKey,
    pub created_at: i64,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ServerState {
    pub gid: String,
    pub owner: Option<PublicKey>,
    pub metadata: Metadata,
    pub structure: Structure,
    pub roles: Vec<Role>,
    pub members: BTreeMap<PublicKey, Member>,
    pub bans: BTreeMap<PublicKey, Ban>,
    pub emojis: Vec<Emoji>,
    pub stickers: Vec<Sticker>,
    pub invites: BTreeMap<String, Invite>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendDenied {
    NotAMember,
    Banned,
    TimedOut { until: i64 },
    NoPermission,
    PostOnly,
}

/// Newest first, ties broken by lowest id (NIP-01).
fn newer(a: &Event, b: &Event) -> bool {
    (a.created_at, std::cmp::Reverse(a.id)) > (b.created_at, std::cmp::Reverse(b.id))
}

fn newest<'a>(events: impl Iterator<Item = &'a Event>) -> Option<&'a Event> {
    events.fold(None, |best: Option<&Event>, e| match best {
        Some(b) if !newer(e, b) => Some(b),
        _ => Some(e),
    })
}

impl ServerState {
    /// Resolves `gid`'s state from `events` (any mix of kinds and servers;
    /// others are ignored). `owner` is the pinned owner key.
    pub fn resolve<'a>(gid: &str, owner: PublicKey, events: impl IntoIterator<Item = &'a Event>) -> Self {
        let mut by_kind: HashMap<u16, Vec<&Event>> = HashMap::new();
        for e in events {
            let kind = e.kind.as_u16();
            if (kinds::SERVER_METADATA..=kinds::SERVER_INVITE).contains(&kind)
                && wire::server_gid(e).as_deref() == Some(gid)
                && d_matches(gid, e)
            {
                by_kind.entry(kind).or_default().push(e);
            }
        }
        let of = |k: u16| by_kind.get(&k).map(Vec::as_slice).unwrap_or(&[]);

        let mut state = ServerState { gid: gid.to_owned(), owner: Some(owner), ..Default::default() };
        // Each pass can only grant permissions justified by the previous
        // pass, so this converges; the cap guards against oscillation from
        // contradictory role edits.
        for _ in 0..8 {
            let before = (state.roles.clone(), state.members.clone(), state.bans.clone());
            state.resolve_pass(of(kinds::SERVER_ROLES), of(kinds::SERVER_MEMBER), of(kinds::SERVER_BAN));
            if (state.roles.clone(), state.members.clone(), state.bans.clone()) == before {
                break;
            }
        }

        let pick = |state: &ServerState, kind: u16| {
            newest(of(kind).iter().copied().filter(|e| state.may_publish(&e.pubkey, kind)))
        };
        state.metadata = pick(&state, kinds::SERVER_METADATA).map(wire::metadata).unwrap_or_default();
        state.structure = pick(&state, kinds::SERVER_STRUCTURE).map(wire::structure).unwrap_or_default();
        state.emojis = state.resolve_custom(
            of(kinds::SERVER_EMOJI), Permission::CreateEmojis, wire::emojis, |e| (e.name.clone(), e.creator),
        );
        state.stickers = state.resolve_custom(
            of(kinds::SERVER_STICKERS), Permission::CreateStickers, wire::stickers, |s| (s.name.to_lowercase(), s.creator),
        );
        state.invites = state.resolve_invites(of(kinds::SERVER_INVITE));
        state
    }

    fn resolve_pass(&mut self, roles: &[&Event], members: &[&Event], bans: &[&Event]) {
        let roles_event = newest(roles.iter().copied().filter(|e| self.may_publish(&e.pubkey, kinds::SERVER_ROLES)));
        let new_roles = roles_event.map(wire::roles).unwrap_or_default();

        // Bans: newest authorized ban event per target.
        let mut new_bans = BTreeMap::new();
        for (target, events) in group_by_target(bans) {
            let latest = newest(events.into_iter().filter(|e| self.has(&e.pubkey, Permission::BanMembers)));
            if let Some(e) = latest {
                let b = wire::ban(e);
                if !b.unbanned {
                    new_bans.insert(target, Ban { reason: b.reason, banned_by: b.banned_by });
                }
            }
        }

        let mut new_members = BTreeMap::new();
        for (target, events) in group_by_target(members) {
            if new_bans.contains_key(&target) {
                continue;
            }
            let is_self = |e: &&Event| e.pubkey == target;
            let manager = |e: &&Event| self.has(&e.pubkey, Permission::ManageRoles);
            let moderator =
                |e: &&Event| self.has(&e.pubkey, Permission::KickMembers) || self.has(&e.pubkey, Permission::ManageRoles);

            // Presence: the subject joins/leaves; moderators can remove.
            let presence = newest(events.iter().copied().filter(|e| is_self(e) || moderator(e)));
            let Some(presence) = presence else { continue };
            let presence_data = wire::member(presence);
            if presence_data.removed {
                continue;
            }

            // Roles only from role managers, never from the subject alone.
            let roles = newest(events.iter().copied().filter(|e| manager(e) && wire::member(e).roles.is_some()))
                .and_then(|e| wire::member(e).roles)
                .unwrap_or_default();

            // Timeouts only from moderators; 0 or past = cleared.
            let timeout_event = newest(
                events.iter().copied().filter(|e| moderator(e) && wire::member(e).timed_out_until.is_some()),
            );
            let timeout = timeout_event.and_then(|e| wire::member(e).timed_out_until).filter(|&t| t > 0);
            let timeout_since = timeout.and(timeout_event).map(|e| e.created_at.as_secs() as i64);

            // Nickname and profile: newest from the subject or a manager.
            let profile_src = newest(events.iter().copied().filter(|e| is_self(e) || manager(e)))
                .map(wire::member)
                .unwrap_or_default();

            new_members.insert(
                target,
                Member {
                    pubkey: target,
                    roles,
                    nickname: profile_src.nickname.filter(|n| !n.is_empty()),
                    joined_at: presence_data.joined_at.or(profile_src.joined_at),
                    profile: profile_src.profile,
                    timed_out_until: timeout,
                    timed_out_since: timeout_since,
                    invite: newest(events.iter().copied().filter(|e| is_self(e) && wire::member(e).invite.is_some()))
                        .and_then(|e| wire::member(e).invite),
                },
            );
        }

        self.roles = new_roles;
        self.bans = new_bans;
        self.members = new_members;
    }

    /// Custom emoji or stickers. The newest list from a `manage_emojis`
    /// holder is the base (managers add, edit and remove anything). Members
    /// who may only create add their own items by publishing a list of their
    /// own; from those, only items they created count, and only if their list
    /// is newer than the base, so a manager's removal sticks. Managers
    /// publish from this merged view, which keeps creators' items.
    fn resolve_custom<T: Clone>(
        &self,
        events: &[&Event],
        create: Permission,
        parse: impl Fn(&Event) -> Vec<T>,
        key: impl Fn(&T) -> (String, Option<PublicKey>),
    ) -> Vec<T> {
        let base = newest(events.iter().copied().filter(|e| self.has(&e.pubkey, Permission::ManageEmojis)));
        let mut items = base.map(&parse).unwrap_or_default();
        let mut names: HashSet<String> = items.iter().map(|i| key(i).0).collect();

        let mut creators: Vec<&Event> = events
            .iter()
            .copied()
            .filter(|e| !self.has(&e.pubkey, Permission::ManageEmojis) && self.has(&e.pubkey, create))
            .filter(|e| base.is_none_or(|b| newer(e, b)))
            .collect();
        // One list per creator (their newest), applied oldest first.
        creators.sort_by_key(|e| (e.created_at, std::cmp::Reverse(e.id)));
        let mut latest_per_creator: HashMap<PublicKey, &Event> = HashMap::new();
        for e in creators {
            latest_per_creator.insert(e.pubkey, e);
        }
        let mut lists: Vec<&Event> = latest_per_creator.into_values().collect();
        lists.sort_by_key(|e| (e.created_at, e.id));
        for e in lists {
            for item in parse(e) {
                let (name, creator) = key(&item);
                if creator == Some(e.pubkey) && names.insert(name) {
                    items.push(item);
                }
            }
        }
        items
    }

    /// The newest word on each code. A revocation counts only from the
    /// invite's creator or someone with manage_invites (Rails' rule), so a
    /// member who may only create invites can't revoke other people's.
    fn resolve_invites(&self, invites: &[&Event]) -> BTreeMap<String, Invite> {
        let mut by_code: HashMap<String, Vec<&Event>> = HashMap::new();
        for e in invites {
            by_code.entry(wire::invite(e).code).or_default().push(e);
        }
        by_code
            .into_iter()
            .filter(|(code, _)| !code.is_empty())
            .filter_map(|(code, events)| {
                let allowed: Vec<&Event> =
                    events.into_iter().filter(|e| self.may_publish(&e.pubkey, kinds::SERVER_INVITE)).collect();
                let first = allowed
                    .iter()
                    .copied()
                    .filter(|e| !wire::invite(e).revoked)
                    .min_by_key(|e| (e.created_at, e.id))?;
                let creator = first.pubkey;
                let e = newest(allowed.iter().copied().filter(|e| {
                    !wire::invite(e).revoked || e.pubkey == creator || self.has(&e.pubkey, Permission::ManageInvites)
                }))?;
                let i = wire::invite(e);
                (!i.revoked).then(|| {
                    let invite = Invite {
                        code: code.clone(),
                        max_uses: i.max_uses,
                        expires_at: i.expires_at,
                        created_by: e.pubkey,
                        created_at: first.created_at.as_secs() as i64,
                    };
                    (code, invite)
                })
            })
            .collect()
    }

    // ─── Queries ─────────────────────────────────────────────────────────

    pub fn is_owner(&self, pk: &PublicKey) -> bool {
        self.owner.as_ref() == Some(pk)
    }

    pub fn is_banned(&self, pk: &PublicKey) -> bool {
        self.bans.contains_key(pk)
    }

    pub fn is_member(&self, pk: &PublicKey) -> bool {
        self.is_owner(pk) || self.members.contains_key(pk)
    }

    /// Server-wide permission, from `@everyone` plus the member's roles.
    pub fn has(&self, pk: &PublicKey, p: Permission) -> bool {
        if self.is_owner(pk) {
            return true;
        }
        if self.is_banned(pk) {
            return false;
        }
        let Some(member) = self.members.get(pk) else { return false };
        let held: HashSet<&str> = member.roles.iter().map(String::as_str).collect();
        self.roles
            .iter()
            .filter(|r| r.is_everyone() || held.contains(r.id.as_str()))
            .any(|r| grants(&r.permissions, p))
    }

    fn may_publish(&self, pk: &PublicKey, kind: u16) -> bool {
        self.is_owner(pk) || required_for(kind).is_some_and(|p| self.has(pk, p))
    }

    pub fn timed_out_until(&self, pk: &PublicKey, now: i64) -> Option<i64> {
        self.members.get(pk)?.timed_out_until.filter(|&t| t > now)
    }

    /// True if `pk` was under a timeout at `at` (for hiding what they sent
    /// during it, whatever their client claimed).
    pub fn was_timed_out_at(&self, pk: &PublicKey, at: i64) -> bool {
        self.members.get(pk).is_some_and(|m| match (m.timed_out_since, m.timed_out_until) {
            (Some(since), Some(until)) => since <= at && at < until,
            _ => false,
        })
    }

    /// Members who joined with `code`.
    pub fn invite_uses(&self, code: &str) -> u32 {
        self.members.values().filter(|m| m.invite.as_deref() == Some(code)).count() as u32
    }

    /// Whether `pk` may revoke `invite` (Rails: its creator or manage_invites).
    pub fn may_revoke(&self, pk: &PublicKey, invite: &Invite) -> bool {
        invite.created_by == *pk || self.has(pk, Permission::ManageInvites)
    }

    pub fn channel(&self, id: &str) -> Option<&Channel> {
        self.structure.channels.iter().find(|c| c.id == id)
    }

    pub fn channel_by_group(&self, group_id: &str) -> Option<&Channel> {
        self.structure.channels.iter().find(|c| c.group_id.as_deref() == Some(group_id))
    }

    /// Whether `pk` may read `channel`. Rails' rule (`Channel#visible_to?`):
    /// plain channels are open to every member; an encrypted channel only to
    /// the owner, admins, and roles in its `allowed_role_ids` override.
    pub fn can_read(&self, pk: &PublicKey, channel: &Channel) -> bool {
        if !self.is_member(pk) || self.is_banned(pk) {
            return false;
        }
        if !channel.encrypted || self.is_owner(pk) || self.has(pk, Permission::Administrator) {
            return true;
        }
        let allowed = allowed_role_ids(channel);
        // `@everyone` in the list means every member. (In Rails, picking it
        // locked everyone out: it's never an assigned membership role.)
        if self.roles.iter().any(|r| r.is_everyone() && allowed.contains(&r.id)) {
            return true;
        }
        self.members.get(pk).is_some_and(|m| m.roles.iter().any(|r| allowed.contains(r)))
    }

    /// Whether `pk` may post in `channel` at `now`. The send path refuses
    /// when this fails, and receivers apply the same check to hide messages.
    pub fn can_send(&self, pk: &PublicKey, channel: &Channel, now: i64) -> Result<(), SendDenied> {
        if self.is_banned(pk) {
            return Err(SendDenied::Banned);
        }
        if !self.is_member(pk) {
            return Err(SendDenied::NotAMember);
        }
        if let Some(until) = self.timed_out_until(pk, now) {
            return Err(SendDenied::TimedOut { until });
        }
        if !self.has(pk, Permission::SendMessages) || !self.can_read(pk, channel) {
            return Err(SendDenied::NoPermission);
        }
        if channel.post_only && !self.has(pk, Permission::ManageMessages) {
            return Err(SendDenied::PostOnly);
        }
        Ok(())
    }

    /// Members in display order: hoisted role groups by role position, then
    /// everyone else; by display name within a group.
    pub fn sorted_members(&self) -> Vec<&Member> {
        let mut out: Vec<&Member> = self.members.values().collect();
        out.sort_by_key(|m| {
            let name = m.nickname.clone().unwrap_or_else(|| {
                if m.profile.display_name.is_empty() { m.profile.name.clone() } else { m.profile.display_name.clone() }
            });
            (std::cmp::Reverse(self.top_hoisted_position(m)), name.to_lowercase())
        });
        out
    }

    fn top_hoisted_position(&self, m: &Member) -> i64 {
        self.roles
            .iter()
            .filter(|r| r.hoist && m.roles.contains(&r.id))
            .map(|r| r.position)
            .max()
            .unwrap_or(i64::MIN)
    }
}

/// Roles allowed into an encrypted channel (`{"allowed_role_ids": [...]}`).
pub fn allowed_role_ids(channel: &Channel) -> Vec<String> {
    channel
        .permission_overrides
        .get("allowed_role_ids")
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
        .unwrap_or_default()
}

/// Per-member kinds must carry the d-tag their `p` tag implies; anything else
/// is a mislabelled or forged copy.
fn d_matches(gid: &str, e: &Event) -> bool {
    let d = e.tags.identifier().unwrap_or_default();
    match e.kind.as_u16() {
        kinds::SERVER_MEMBER => wire::target(e).is_some_and(|p| d == dtag::member(gid, &p.to_hex())),
        kinds::SERVER_BAN => wire::target(e).is_some_and(|p| d == dtag::ban(gid, &p.to_hex())),
        kinds::SERVER_INVITE => d == dtag::invite(gid, &wire::invite(e).code),
        kinds::SERVER_METADATA => d == dtag::metadata(gid),
        kinds::SERVER_STRUCTURE => d == dtag::structure(gid),
        kinds::SERVER_ROLES => d == dtag::roles(gid),
        kinds::SERVER_EMOJI => d == dtag::emojis(gid),
        kinds::SERVER_STICKERS => d == dtag::stickers(gid),
        _ => false,
    }
}

fn group_by_target<'a>(events: &[&'a Event]) -> HashMap<PublicKey, Vec<&'a Event>> {
    let mut out: HashMap<PublicKey, Vec<&Event>> = HashMap::new();
    for e in events {
        if let Some(t) = wire::target(e) {
            out.entry(t).or_default().push(e);
        }
    }
    out
}

#[cfg(test)]
mod tests;
