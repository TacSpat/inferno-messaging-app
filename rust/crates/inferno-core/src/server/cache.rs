//! Loading a server's state from the local cache.

use nostr::prelude::*;
use rusqlite::params;

use super::ServerState;
use crate::store::{events::parse, Result, Store};
use crate::{dtag, kinds};

fn owner_key(gid: &str) -> String {
    format!("server.owner.{gid}")
}

impl Store {
    /// Records who owns `gid`. Set once when joining, from the invite's
    /// author, and only replaced by an explicit transfer.
    pub fn pin_server_owner(&self, gid: &str, owner: &PublicKey) -> Result<()> {
        self.set_setting(&owner_key(gid), &owner.to_hex())
    }

    pub fn server_owner(&self, gid: &str) -> Result<Option<PublicKey>> {
        let hex: Option<String> = self.get_setting(&owner_key(gid))?;
        Ok(hex.and_then(|h| PublicKey::from_hex(&h).ok()))
    }

    /// Every cached state event for `gid`, from any signer.
    pub fn server_events(&self, gid: &str) -> Result<Vec<Event>> {
        let exact = [dtag::metadata(gid), dtag::structure(gid), dtag::roles(gid), dtag::emojis(gid), dtag::stickers(gid)];
        let prefixes = [dtag::member_prefix(gid), dtag::ban_prefix(gid), dtag::invite_prefix(gid)];
        let conn = self.conn();
        // substr instead of LIKE: gids may contain `_`, a LIKE wildcard.
        let mut stmt = conn.prepare_cached(
            "SELECT json FROM events
             WHERE kind BETWEEN ?1 AND ?2 AND address_d IS NOT NULL
               AND (address_d IN (?3, ?4, ?5, ?6, ?7)
                    OR substr(address_d, 1, length(?8)) = ?8
                    OR substr(address_d, 1, length(?9)) = ?9
                    OR substr(address_d, 1, length(?10)) = ?10)",
        )?;
        let rows = stmt.query_map(
            params![
                kinds::SERVER_METADATA, kinds::SERVER_INVITE,
                exact[0], exact[1], exact[2], exact[3], exact[4],
                prefixes[0], prefixes[1], prefixes[2],
            ],
            |r| r.get::<_, String>(0),
        )?;
        rows.map(|j| parse(&j?)).collect()
    }

    /// The server's resolved state, or `None` if no owner is pinned yet.
    pub fn load_server(&self, gid: &str) -> Result<Option<ServerState>> {
        let Some(owner) = self.server_owner(gid)? else { return Ok(None) };
        let events = self.server_events(gid)?;
        Ok(Some(ServerState::resolve(gid, owner, &events)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn loads_only_this_servers_events_and_needs_a_pinned_owner() {
        let store = Store::open_in_memory().unwrap();
        let owner = Keys::generate();
        let alice = Keys::generate();
        let ev = |gid: &str, kind: u16, d: String, extra: Vec<Vec<&str>>| {
            let mut tags = vec![Tag::identifier(d), Tag::parse(["server", gid]).unwrap()];
            tags.extend(extra.into_iter().map(|t| Tag::parse(t).unwrap()));
            EventBuilder::new(Kind::Custom(kind), "").tags(tags).finalize(&owner).unwrap()
        };
        let a_pk = alice.public_key().to_hex();
        // "inferno-a_b" vs "inferno-aXb": `_` must not match any character.
        for gid in ["inferno-a_b", "inferno-aXb"] {
            store.put_event(&ev(gid, kinds::SERVER_ROLES, dtag::roles(gid), vec![])).unwrap();
            store
                .put_event(&ev(gid, kinds::SERVER_MEMBER, dtag::member(gid, &a_pk), vec![vec!["p", &a_pk]]))
                .unwrap();
        }

        assert!(store.load_server("inferno-a_b").unwrap().is_none(), "no owner pinned");
        assert_eq!(store.server_events("inferno-a_b").unwrap().len(), 2);

        store.pin_server_owner("inferno-a_b", &owner.public_key()).unwrap();
        let state = store.load_server("inferno-a_b").unwrap().unwrap();
        assert!(state.is_member(&alice.public_key()));
    }
}
