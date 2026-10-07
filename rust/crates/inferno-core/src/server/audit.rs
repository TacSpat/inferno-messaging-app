//! The audit log: who changed what in a server, from the state events we
//! hold. Rails and Flutter only named the event kind ("updated a member");
//! this says what happened to whom. Events from signers without the
//! authority for them are left out, as they don't count either.

use nostr::prelude::*;

use super::state::ServerState;
use super::wire;
use crate::kinds;

#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    Settings,
    Channels,
    Roles,
    Emojis,
    Stickers,
    Joined,
    Left,
    Kicked(PublicKey),
    /// For this many seconds.
    TimedOut { target: PublicKey, secs: i64 },
    TimeoutLifted(PublicKey),
    RolesChanged(PublicKey),
    Banned { target: PublicKey, reason: String },
    Unbanned(PublicKey),
    InviteCreated,
    InviteRevoked,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    pub at: i64,
    pub actor: PublicKey,
    pub action: Action,
}

/// A member's own event within this long of its `joined_at` is the join;
/// later ones are profile refreshes, which aren't logged.
const JOIN_WINDOW: i64 = 120;

/// Newest first.
pub fn entries(state: &ServerState, events: &[Event]) -> Vec<Entry> {
    let mut out: Vec<Entry> = events.iter().filter_map(|e| entry(state, e)).collect();
    out.sort_by(|a, b| b.at.cmp(&a.at));
    out
}

fn entry(state: &ServerState, e: &Event) -> Option<Entry> {
    if wire::server_gid(e).as_deref() != Some(state.gid.as_str()) {
        return None;
    }
    let kind = e.kind.as_u16();
    let at = e.created_at.as_secs() as i64;
    let entry = |action| Some(Entry { at, actor: e.pubkey, action });
    // A member's own join or leave needs no authority.
    if kind == kinds::SERVER_MEMBER && wire::target(e) == Some(e.pubkey) {
        let m = wire::member(e);
        if m.removed {
            return entry(Action::Left);
        }
        return match m.joined_at {
            Some(j) if (at - j).abs() <= JOIN_WINDOW => entry(Action::Joined),
            _ => None,
        };
    }
    if !state.may_publish(&e.pubkey, kind) {
        return None;
    }
    match kind {
        kinds::SERVER_METADATA => entry(Action::Settings),
        kinds::SERVER_STRUCTURE => entry(Action::Channels),
        kinds::SERVER_ROLES => entry(Action::Roles),
        kinds::SERVER_EMOJI => entry(Action::Emojis),
        kinds::SERVER_STICKERS => entry(Action::Stickers),
        kinds::SERVER_MEMBER => {
            let target = wire::target(e)?;
            let m = wire::member(e);
            if m.removed {
                entry(Action::Kicked(target))
            } else {
                // Our events say which change they are (each restates
                // the rest); Rails' and Flutter's carry one change each.
                let action = e.tags.iter().find(|t| t.kind().to_string() == "action").and_then(|t| t.content()).map(str::to_owned);
                match (action.as_deref(), m.timed_out_until) {
                    (Some("roles"), _) => entry(Action::RolesChanged(target)),
                    (_, Some(until)) if until > at => entry(Action::TimedOut { target, secs: until - at }),
                    (_, Some(_)) => entry(Action::TimeoutLifted(target)),
                    (_, None) if m.roles.is_some() => entry(Action::RolesChanged(target)),
                    _ => None,
                }
            }
        }
        kinds::SERVER_BAN => {
            let target = wire::target(e)?;
            let b = wire::ban(e);
            if b.unbanned { entry(Action::Unbanned(target)) } else { entry(Action::Banned { target, reason: b.reason }) }
        }
        kinds::SERVER_INVITE => {
            if wire::invite(e).revoked { entry(Action::InviteRevoked) } else { entry(Action::InviteCreated) }
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::publish;

    #[test]
    fn describes_what_happened_and_skips_what_doesnt_count() {
        let owner = Keys::generate();
        let alice = Keys::generate();
        let mallory = Keys::generate();
        let (gid, mut events) = publish::create_server(&owner, "x").unwrap();
        let profile = wire::MemberProfile::default();
        let now = crate::store::now_secs();
        events.push(publish::join(&alice, &gid, "", &profile, now, None, &[]).unwrap());
        events.push(publish::join(&mallory, &gid, "", &profile, now, None, &[]).unwrap());
        let state = ServerState::resolve(&gid, owner.public_key(), &events);
        events.push(publish::ban(&owner, &state, &mallory.public_key(), "spam").unwrap());
        // Alice can't ban; her attempt isn't logged as a ban.
        let mut forged = state.clone();
        forged.owner = Some(alice.public_key());
        events.push(publish::ban(&alice, &forged, &owner.public_key(), "lol").unwrap());
        let state = ServerState::resolve(&gid, owner.public_key(), &events);

        let log = entries(&state, &events);
        let actions: Vec<_> = log.iter().map(|e| (e.actor, e.action.clone())).collect();
        assert!(actions.contains(&(alice.public_key(), Action::Joined)));
        assert!(actions.contains(&(owner.public_key(), Action::Banned { target: mallory.public_key(), reason: "spam".into() })));
        assert!(!actions.iter().any(|(a, act)| *a == alice.public_key() && matches!(act, Action::Banned { .. })));
        assert!(actions.contains(&(owner.public_key(), Action::Roles)));

        let role = state.roles[0].id.clone();
        let mut ev = |e: Event| events.push(e);
        let until = now + 3600;
        ev(publish::set_roles(&owner, &state, &alice.public_key(), &[role]).unwrap());
        let state = ServerState::resolve(&gid, owner.public_key(), &events);
        let t = publish::timeout(&owner, &state, &alice.public_key(), until).unwrap();
        let at = t.created_at.as_secs() as i64;
        let log = entries(&state, &[t]);
        assert_eq!(log[0].action, Action::TimedOut { target: alice.public_key(), secs: until - at }, "even though it restates her roles");
    }
}
