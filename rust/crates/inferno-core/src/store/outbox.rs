//! The outbox: events waiting for a relay to take them.

use nostr::prelude::*;
use rusqlite::params;

use super::events::parse;
use super::{Result, Store};

/// One waiting event.
#[derive(Debug, Clone)]
pub struct Queued {
    pub event: Event,
    /// Relays still to reach; empty: any one of ours will do.
    pub relays: Vec<String>,
    pub attempts: u32,
}

/// A replaceable or addressable event's address (`kind:pubkey:d`).
fn address(event: &Event) -> Option<String> {
    let d = if event.kind.is_addressable() {
        event.tags.identifier().unwrap_or_default().to_owned()
    } else if event.kind.is_replaceable() {
        String::new()
    } else {
        return None;
    };
    Some(format!("{}:{}:{d}", event.kind.as_u16(), event.pubkey.to_hex()))
}

impl Store {
    /// Queues `event` for `relays` (empty: any of ours), first try at
    /// `next_at`. A queued older copy of the same address is dropped (only
    /// the newest is worth sending); a re-queue keeps its attempt count.
    pub fn queue_event(&self, event: &Event, shows_as: &str, relays: &[String], next_at: u64) -> Result<()> {
        let conn = self.conn();
        let address = address(event);
        if let Some(a) = &address {
            conn.execute("DELETE FROM outbox WHERE address = ?1 AND event_id != ?2", params![a, event.id.to_hex()])?;
        }
        let relays = serde_json::to_string(relays).unwrap_or_else(|_| "[]".into());
        conn.execute(
            "INSERT INTO outbox (event_id, json, shows_as, address, relays, attempts, next_at, added_at)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, ?6, ?7)
             ON CONFLICT (event_id) DO UPDATE SET relays = excluded.relays, next_at = excluded.next_at",
            params![event.id.to_hex(), event.as_json(), shows_as, address, relays, next_at as i64, Timestamp::now().as_secs() as i64],
        )?;
        Ok(())
    }

    /// Events due by `now`, oldest first.
    pub fn due_events(&self, now: u64) -> Result<Vec<Queued>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT json, relays, attempts FROM outbox WHERE next_at <= ?1 ORDER BY added_at")?;
        let rows = stmt.query_map([now as i64], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)))?;
        let mut out = Vec::new();
        for row in rows {
            let (json, relays, attempts) = row?;
            out.push(Queued { event: parse(&json)?, relays: serde_json::from_str(&relays).unwrap_or_default(), attempts: attempts as u32 });
        }
        Ok(out)
    }

    /// Another try failed: wait until `next_at`, for `relays`.
    pub fn retry_event(&self, id: &EventId, relays: &[String], next_at: u64) -> Result<()> {
        let relays = serde_json::to_string(relays).unwrap_or_else(|_| "[]".into());
        self.conn().execute(
            "UPDATE outbox SET attempts = attempts + 1, relays = ?2, next_at = ?3 WHERE event_id = ?1",
            params![id.to_hex(), relays, next_at as i64],
        )?;
        Ok(())
    }

    /// Sent (or given up on).
    pub fn unqueue_event(&self, id: &EventId) -> Result<()> {
        self.conn().execute("DELETE FROM outbox WHERE event_id = ?1", [id.to_hex()])?;
        Ok(())
    }

    /// The ids the UI shows waiting events by.
    pub fn queued_ids(&self) -> Result<Vec<String>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT shows_as FROM outbox")?;
        let ids = stmt.query_map([], |r| r.get(0))?.collect::<std::result::Result<Vec<String>, _>>()?;
        Ok(ids)
    }

    /// Everything queued, now (sending again at once, as when relays come
    /// back).
    pub fn hurry_queue(&self) -> Result<()> {
        self.conn().execute("UPDATE outbox SET next_at = 0", [])?;
        Ok(())
    }
}
