use nostr::prelude::*;
use rusqlite::{params, OptionalExtension, Transaction};

use super::{now_secs, Result, Store, StoreError};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PutOutcome {
    Inserted,
    /// Same id already stored.
    Duplicate,
    /// A newer copy of this replaceable/addressable event is already stored.
    Stale,
    /// The event was deleted (NIP-09) and stays deleted.
    Deleted,
}

/// '' for replaceable kinds (one per author), the d-tag for addressable ones.
fn address_d(event: &Event) -> Option<String> {
    if event.kind.is_replaceable() {
        Some(String::new())
    } else if event.kind.is_addressable() {
        Some(event.tags.identifier().unwrap_or_default().to_owned())
    } else {
        None
    }
}

impl Store {
    /// Stores a verified event. Callers must have checked the signature;
    /// nostr-sdk does this for everything it delivers.
    pub fn put_event(&self, event: &Event) -> Result<PutOutcome> {
        let mut conn = self.conn();
        let tx = conn.transaction()?;
        let outcome = put_in(&tx, event)?;
        tx.commit()?;
        Ok(outcome)
    }

    pub fn get_event(&self, id: &EventId) -> Result<Option<Event>> {
        let conn = self.conn();
        let json: Option<String> = conn
            .query_row("SELECT json FROM events WHERE id = ?1", [id.to_hex()], |r| r.get(0))
            .optional()?;
        json.map(|j| parse(&j)).transpose()
    }

    /// The current copy of a replaceable (`d` = "") or addressable event.
    pub fn get_addressable(&self, kind: Kind, author: &PublicKey, d: &str) -> Result<Option<Event>> {
        let conn = self.conn();
        let json: Option<String> = conn
            .query_row(
                "SELECT json FROM events WHERE kind = ?1 AND pubkey = ?2 AND address_d = ?3",
                params![kind.as_u16(), author.to_hex(), d],
                |r| r.get(0),
            )
            .optional()?;
        json.map(|j| parse(&j)).transpose()
    }

    /// Events of `kind` carrying tag `name` = `value`, newest first.
    pub fn events_by_tag(
        &self,
        kind: Kind,
        name: char,
        value: &str,
        limit: usize,
    ) -> Result<Vec<Event>> {
        let conn = self.conn();
        let mut stmt = conn.prepare_cached(
            "SELECT e.json FROM events e
             JOIN event_tags t ON t.event_id = e.id
             WHERE t.name = ?1 AND t.value = ?2 AND e.kind = ?3
             ORDER BY e.created_at DESC LIMIT ?4",
        )?;
        let rows = stmt.query_map(
            params![name.to_string(), value, kind.as_u16(), limit as i64],
            |r| r.get::<_, String>(0),
        )?;
        rows.map(|j| parse(&j?)).collect()
    }

    pub fn is_deleted(&self, id: &EventId) -> Result<bool> {
        let conn = self.conn();
        Ok(conn
            .query_row("SELECT 1 FROM deleted_events WHERE event_id = ?1", [id.to_hex()], |_| Ok(()))
            .optional()?
            .is_some())
    }
}

fn put_in(tx: &Transaction, event: &Event) -> Result<PutOutcome> {
    let id = event.id.to_hex();
    let pubkey = event.pubkey.to_hex();
    // A tombstone only counts if the deleter is the author: anyone can name an
    // id we haven't seen yet, so this is checked when the event arrives.
    let deleted_by: Option<String> = tx
        .query_row("SELECT deleted_by FROM deleted_events WHERE event_id = ?1", [&id], |r| r.get(0))
        .optional()?;
    if deleted_by.as_deref() == Some(pubkey.as_str()) {
        return Ok(PutOutcome::Deleted);
    }
    if tx.query_row("SELECT 1 FROM events WHERE id = ?1", [&id], |_| Ok(())).optional()?.is_some() {
        return Ok(PutOutcome::Duplicate);
    }

    let address = address_d(event);
    if let Some(d) = &address {
        let deleted_at: Option<i64> = tx
            .query_row(
                "SELECT deleted_at FROM deleted_addresses WHERE kind = ?1 AND pubkey = ?2 AND address_d = ?3",
                params![event.kind.as_u16(), pubkey, d],
                |r| r.get(0),
            )
            .optional()?;
        if deleted_at.is_some_and(|at| event.created_at.as_secs() as i64 <= at) {
            return Ok(PutOutcome::Deleted);
        }
        let current: Option<(String, i64)> = tx
            .query_row(
                "SELECT id, created_at FROM events WHERE kind = ?1 AND pubkey = ?2 AND address_d = ?3",
                params![event.kind.as_u16(), pubkey, d],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        if let Some((current_id, current_at)) = current {
            // NIP-01: newer created_at wins; on a tie the lowest id wins.
            let incoming_at = event.created_at.as_secs() as i64;
            if (incoming_at, std::cmp::Reverse(&id)) <= (current_at, std::cmp::Reverse(&current_id)) {
                return Ok(PutOutcome::Stale);
            }
            tx.execute("DELETE FROM events WHERE id = ?1", [&current_id])?;
        }
    }

    tx.execute(
        "INSERT INTO events (id, kind, pubkey, created_at, address_d, json, received_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        params![
            id,
            event.kind.as_u16(),
            pubkey,
            event.created_at.as_secs() as i64,
            address,
            event.as_json(),
            now_secs(),
        ],
    )?;
    {
        let mut stmt =
            tx.prepare_cached("INSERT INTO event_tags (event_id, name, value) VALUES (?1, ?2, ?3)")?;
        for tag in event.tags.iter() {
            let slice = tag.as_slice();
            if let (Some(name), Some(value)) = (slice.first(), slice.get(1)) {
                if name.len() == 1 {
                    stmt.execute(params![id, name, value])?;
                }
            }
        }
    }

    if event.kind == Kind::EventDeletion {
        apply_deletion(tx, event)?;
    }
    Ok(PutOutcome::Inserted)
}

/// NIP-09: only the author may delete. `e` tags name events; `a` tags name
/// addresses (`kind:pubkey:d`), deleting every copy up to the request's time.
fn apply_deletion(tx: &Transaction, deletion: &Event) -> Result<()> {
    let author = deletion.pubkey.to_hex();
    let at = deletion.created_at.as_secs() as i64;
    let mut targets: Vec<String> = Vec::new();

    for id in deletion.tags.event_ids() {
        let id = id.to_hex();
        let owner: Option<String> = tx
            .query_row("SELECT pubkey FROM events WHERE id = ?1", [&id], |r| r.get(0))
            .optional()?;
        // Unseen ids get a tombstone too; put_in only honours it if the
        // event's author turns out to be the deleter.
        if owner.is_none_or(|owner| owner == author) {
            targets.push(id);
        }
    }

    for coordinate in deletion.tags.coordinates() {
        if coordinate.public_key.to_hex() != author {
            continue;
        }
        tx.execute(
            "INSERT INTO deleted_addresses (kind, pubkey, address_d, deleted_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT (kind, pubkey, address_d) DO UPDATE SET deleted_at = max(deleted_at, excluded.deleted_at)",
            params![coordinate.kind.as_u16(), author, coordinate.identifier, at],
        )?;
        let mut stmt = tx.prepare_cached(
            "SELECT id FROM events WHERE kind = ?1 AND pubkey = ?2 AND address_d = ?3 AND created_at <= ?4",
        )?;
        let ids = stmt.query_map(
            params![coordinate.kind.as_u16(), author, coordinate.identifier, at],
            |r| r.get::<_, String>(0),
        )?;
        for id in ids {
            targets.push(id?);
        }
    }

    for id in targets {
        tx.execute(
            "INSERT INTO deleted_events (event_id, deleted_by, deleted_at) VALUES (?1, ?2, ?3)
             ON CONFLICT (event_id) DO NOTHING",
            params![id, author, at],
        )?;
        tx.execute("DELETE FROM events WHERE id = ?1", [&id])?;
    }
    Ok(())
}

pub(crate) fn parse(json: &str) -> Result<Event> {
    Event::from_json(json).map_err(|e| StoreError::Corrupt(e.to_string()))
}

impl Store {
    /// Newest `created_at` among cached events of `kinds` tagged `name` with
    /// any of `values`. Subscriptions start from here instead of re-fetching
    /// history relays already gave us.
    pub fn newest_tagged(&self, kinds: &[u16], name: char, values: &[String]) -> Result<Option<i64>> {
        let conn = self.conn();
        let mut stmt = conn.prepare_cached(
            "SELECT max(e.created_at) FROM events e JOIN event_tags t ON t.event_id = e.id
             WHERE t.name = ?1 AND t.value = ?2 AND e.kind = ?3",
        )?;
        let mut newest: Option<i64> = None;
        for value in values {
            for kind in kinds {
                let at: Option<i64> = stmt.query_row(params![name.to_string(), value, kind], |r| r.get(0))?;
                newest = newest.max(at);
            }
        }
        Ok(newest)
    }

    /// Of `authors`, those with a stored event of `kind`, and the newest such
    /// event's time: the point a catch-up fetch can resume from.
    pub fn authors_with(&self, kind: u16, authors: &[String]) -> Result<(std::collections::HashSet<String>, Option<i64>)> {
        let conn = self.conn();
        let mut stmt = conn.prepare_cached("SELECT max(created_at) FROM events WHERE kind = ?1 AND pubkey = ?2")?;
        let mut have = std::collections::HashSet::new();
        let mut newest = None;
        for a in authors {
            let at: Option<i64> = stmt.query_row(params![kind, a], |r| r.get(0))?;
            if at.is_some() {
                have.insert(a.clone());
                newest = newest.max(at);
            }
        }
        Ok((have, newest))
    }

    /// Each author's newest stored event of any kind.
    pub fn last_seen(&self, authors: &[String]) -> Result<std::collections::HashMap<String, i64>> {
        let conn = self.conn();
        let mut stmt = conn.prepare_cached("SELECT max(created_at) FROM events WHERE pubkey = ?1")?;
        let mut out = std::collections::HashMap::new();
        for a in authors {
            if let Some(at) = stmt.query_row(params![a], |r| r.get::<_, Option<i64>>(0))? {
                out.insert(a.clone(), at);
            }
        }
        Ok(out)
    }

    /// The newest stored event of any of `kinds`.
    pub fn newest_of_kinds(&self, kinds: &[u16]) -> Result<Option<i64>> {
        let conn = self.conn();
        let mut stmt = conn.prepare_cached("SELECT max(created_at) FROM events WHERE kind = ?1")?;
        let mut newest = None;
        for k in kinds {
            let at: Option<i64> = stmt.query_row(params![k], |r| r.get(0))?;
            newest = newest.max(at);
        }
        Ok(newest)
    }
}
