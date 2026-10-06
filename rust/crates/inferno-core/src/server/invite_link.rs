//! Invite links: NIP-19 `naddr` for the kind 31757 invite event, as Rails
//! (`Invite#to_naddr`) and Flutter (`inviteNaddr`) encode them.
//!
//! Two identifier forms exist:
//! - compact `inv-{server_public_id}-{code}` (current), where the gid is
//!   `inferno-{server_public_id}`;
//! - legacy `inferno-invite-{gid}-{code}`.
//!
//! The naddr's author is the invite's creator. Joining pins that key as the
//! server's owner (see `Store::pin_server_owner`).

use nostr::nips::nip19::{FromBech32, Nip19Coordinate, ToBech32};
use nostr::prelude::*;

use crate::kinds;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InviteLink {
    pub gid: String,
    pub code: String,
    pub author: PublicKey,
    pub relays: Vec<String>,
}

fn alnum(s: &str) -> bool {
    !s.is_empty() && s.bytes().all(|b| b.is_ascii_alphanumeric())
}

/// Accepts `naddr1…` with or without a `nostr:` prefix.
pub fn parse(link: &str) -> Option<InviteLink> {
    let raw = link.trim().strip_prefix("nostr:").unwrap_or(link.trim());
    let n = Nip19Coordinate::from_bech32(raw).ok()?;
    if n.coordinate.kind != Kind::Custom(kinds::SERVER_INVITE) {
        return None;
    }
    let id = n.coordinate.identifier.as_str();
    let (gid, code) = if let Some(rest) = id.strip_prefix("inv-") {
        let (public_id, code) = rest.split_once('-')?;
        (alnum(public_id) && alnum(code)).then(|| (format!("inferno-{public_id}"), code.to_owned()))?
    } else {
        // inferno-invite-inferno-{public_id}-{code}
        let rest = id.strip_prefix("inferno-invite-inferno-")?;
        let (public_id, code) = rest.split_once('-')?;
        (alnum(public_id) && alnum(code)).then(|| (format!("inferno-{public_id}"), code.to_owned()))?
    };
    Some(InviteLink {
        gid,
        code,
        author: n.coordinate.public_key,
        relays: n.relays.iter().map(|r| r.to_string()).collect(),
    })
}

/// Encodes in the compact form. `gid` must be `inferno-{public_id}`.
pub fn encode(gid: &str, code: &str, author: &PublicKey, relays: &[String]) -> Option<String> {
    let public_id = gid.strip_prefix("inferno-").filter(|p| alnum(p))?;
    let coordinate = Coordinate::new(Kind::Custom(kinds::SERVER_INVITE), *author)
        .identifier(format!("inv-{public_id}-{code}"));
    let relays = relays.iter().filter_map(|r| RelayUrl::parse(r).ok());
    Nip19Coordinate::new(coordinate, relays).to_bech32().ok().map(|n| format!("nostr:{n}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn compact_round_trip() {
        let author = Keys::generate().public_key();
        let link = encode("inferno-Ab3dE6gH9jK1", "XyZ9", &author, &["wss://relay.damus.io".into()]).unwrap();
        assert!(link.starts_with("nostr:naddr1"));
        let parsed = parse(&link).unwrap();
        assert_eq!(parsed.gid, "inferno-Ab3dE6gH9jK1");
        assert_eq!(parsed.code, "XyZ9");
        assert_eq!(parsed.author, author);
        assert_eq!(parsed.relays, vec!["wss://relay.damus.io".to_string()]);
        assert_eq!(parse(link.strip_prefix("nostr:").unwrap()), Some(parsed));
    }

    #[test]
    fn legacy_identifier() {
        let author = Keys::generate().public_key();
        let c = Coordinate::new(Kind::Custom(kinds::SERVER_INVITE), author)
            .identifier("inferno-invite-inferno-Ab3dE6gH9jK1-XyZ9");
        let naddr = Nip19Coordinate::new(c, Vec::<RelayUrl>::new()).to_bech32().unwrap();
        let parsed = parse(&naddr).unwrap();
        assert_eq!((parsed.gid.as_str(), parsed.code.as_str()), ("inferno-Ab3dE6gH9jK1", "XyZ9"));
    }

    #[test]
    fn rejects_other_kinds_and_junk() {
        let author = Keys::generate().public_key();
        let wrong_kind = Coordinate::new(Kind::Custom(30023), author).identifier("inv-abc-def");
        assert!(parse(&Nip19Coordinate::new(wrong_kind, Vec::<RelayUrl>::new()).to_bech32().unwrap()).is_none());
        assert!(parse("naddr1garbage").is_none());
        assert!(encode("not-inferno", "x", &author, &[]).is_none());
    }
}

/// Picks the owner to pin when joining through `link`, from the server's
/// fetched state events.
///
/// Any member with `create_invite` can make an invite, so the link's author
/// isn't necessarily the owner. Candidates are the author and every key
/// whose own metadata claims the server. A candidate other than the author
/// wins if, resolved under it, the author is a member allowed to invite and
/// the invite is on record. Otherwise the author owns it. Either way we only
/// trust what the person who handed us the link vouches for.
pub fn resolve_owner(link: &InviteLink, events: &[Event]) -> PublicKey {
    use crate::server::{state::ServerState, wire, Permission};

    let mut candidates: Vec<PublicKey> = events
        .iter()
        .filter(|e| e.kind == Kind::Custom(kinds::SERVER_METADATA))
        .filter(|e| wire::server_gid(e).as_deref() == Some(link.gid.as_str()))
        .filter(|e| wire::metadata(e).owner == Some(e.pubkey) && e.pubkey != link.author)
        .map(|e| e.pubkey)
        .collect();
    candidates.sort();
    candidates.dedup();

    candidates
        .into_iter()
        .find(|owner| {
            let state = ServerState::resolve(&link.gid, *owner, events);
            state.is_member(&link.author)
                && state.has(&link.author, Permission::CreateInvite)
                && state.invites.get(&link.code).is_some_and(|i| i.created_by == link.author)
        })
        .unwrap_or(link.author)
}

#[cfg(test)]
mod owner_tests {
    use super::*;
    use crate::server::publish;
    use crate::server::state::ServerState;

    #[test]
    fn a_members_invite_pins_the_real_owner_not_the_inviter() {
        let owner = Keys::generate();
        let alice = Keys::generate();
        let (gid, mut events) = publish::create_server(&owner, "real").unwrap();
        events.push(publish::join(&alice, &gid, "", &Default::default(), 0).unwrap());
        let state = ServerState::resolve(&gid, owner.public_key(), &events);
        events.push(publish::invite(&alice, &state, "AAA", 0, 0).unwrap());

        let link = parse(&encode(&gid, "AAA", &alice.public_key(), &[]).unwrap()).unwrap();
        assert_eq!(resolve_owner(&link, &events), owner.public_key());
    }

    #[test]
    fn a_fake_owner_claim_does_not_win() {
        let owner = Keys::generate();
        let mallory = Keys::generate();
        let (gid, mut events) = publish::create_server(&owner, "real").unwrap();
        let state = ServerState::resolve(&gid, owner.public_key(), &events);
        events.push(publish::invite(&owner, &state, "OWN", 0, 0).unwrap());
        // Mallory claims the same gid in her own metadata.
        let fake = ServerState { gid: gid.clone(), owner: Some(mallory.public_key()), ..Default::default() };
        events.push(publish::metadata(&mallory, &fake, &Default::default()).unwrap());

        let link = parse(&encode(&gid, "OWN", &owner.public_key(), &[]).unwrap()).unwrap();
        assert_eq!(resolve_owner(&link, &events), owner.public_key());
    }
}
