//! The decrypted DM cache.

use nostr_sdk::prelude::{EventId, PublicKey};
use rusqlite::params;

use super::{Result, Store};
use crate::social::Rumor;

fn row(r: &rusqlite::Row) -> rusqlite::Result<Option<Rumor>> {
    let (id, sender, counterparty): (String, String, String) = (r.get(0)?, r.get(1)?, r.get(2)?);
    Ok((|| {
        Some(Rumor {
            id: EventId::from_hex(&id).ok()?,
            sender: PublicKey::from_hex(&sender).ok()?,
            counterparty: PublicKey::from_hex(&counterparty).ok()?,
            created_at: r.get(3).ok()?,
            body: r.get(4).ok()?,
        })
    })())
}

impl Store {
    /// Whether this wrap was already opened (successfully or not).
    pub fn dm_opened(&self, wrap: &EventId) -> Result<bool> {
        let conn = self.conn();
        Ok(conn.query_row("SELECT 1 FROM dm_opened WHERE wrap_id = ?1", [wrap.to_hex()], |_| Ok(())).is_ok())
    }

    pub fn mark_dm_opened(&self, wrap: &EventId) -> Result<()> {
        self.conn().execute("INSERT OR IGNORE INTO dm_opened (wrap_id) VALUES (?1)", [wrap.to_hex()])?;
        Ok(())
    }

    /// Stores a rumor; false if we already had it (it came in another wrap).
    pub fn put_rumor(&self, r: &Rumor) -> Result<bool> {
        let n = self.conn().execute(
            "INSERT OR IGNORE INTO dm_rumors (id, sender, counterparty, created_at, body) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![r.id.to_hex(), r.sender.to_hex(), r.counterparty.to_hex(), r.created_at, r.body],
        )?;
        Ok(n > 0)
    }

    pub fn rumors(&self) -> Result<Vec<Rumor>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT id, sender, counterparty, created_at, body FROM dm_rumors ORDER BY created_at")?;
        let rows = stmt.query_map([], row)?.filter_map(|r| r.ok().flatten()).collect();
        Ok(rows)
    }

    pub fn rumors_with(&self, counterparty: &PublicKey) -> Result<Vec<Rumor>> {
        let conn = self.conn();
        let mut stmt = conn.prepare(
            "SELECT id, sender, counterparty, created_at, body FROM dm_rumors WHERE counterparty = ?1 ORDER BY created_at",
        )?;
        let rows = stmt.query_map([counterparty.to_hex()], row)?.filter_map(|r| r.ok().flatten()).collect();
        Ok(rows)
    }
}
