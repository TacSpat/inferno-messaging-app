//! Device-local state: relays, read markers, blocks and settings.

use std::collections::HashMap;

use rusqlite::{params, OptionalExtension};
use serde::{de::DeserializeOwned, Serialize};

use super::{now_secs, Result, Store, StoreError};
use crate::relay::{normalize_url, DEFAULT_RELAYS};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelaySource {
    Default,
    User,
    /// Learned from the user's NIP-65 relay list on another device.
    Nip65,
}

impl RelaySource {
    fn as_str(self) -> &'static str {
        match self {
            Self::Default => "default",
            Self::User => "user",
            Self::Nip65 => "nip65",
        }
    }

    fn parse(s: &str) -> Self {
        match s {
            "user" => Self::User,
            "nip65" => Self::Nip65,
            _ => Self::Default,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RelayRow {
    pub url: String,
    pub read: bool,
    pub write: bool,
    pub source: RelaySource,
}

fn relay_key(url: &str) -> Result<String> {
    normalize_url(url).ok_or_else(|| StoreError::InvalidRelayUrl(url.to_owned()))
}

impl Store {
    /// Adds any default relay that's missing. Never removes anything: relays
    /// the user added or learned via NIP-65 must survive restarts. Flutter's
    /// version deleted every non-default relay on each launch.
    pub fn seed_default_relays(&self) -> Result<()> {
        for url in DEFAULT_RELAYS {
            self.add_relay(url, RelaySource::Default)?;
        }
        Ok(())
    }

    /// Adds a relay; a relay that's already present keeps its settings.
    pub fn add_relay(&self, url: &str, source: RelaySource) -> Result<()> {
        let url = relay_key(url)?;
        self.conn().execute(
            "INSERT INTO relays (url, source, added_at) VALUES (?1, ?2, ?3)
             ON CONFLICT (url) DO NOTHING",
            params![url, source.as_str(), now_secs()],
        )?;
        Ok(())
    }

    /// Removing a relay is only ever an explicit user action.
    pub fn remove_relay(&self, url: &str) -> Result<()> {
        self.conn().execute("DELETE FROM relays WHERE url = ?1", [relay_key(url)?])?;
        Ok(())
    }

    pub fn relays(&self) -> Result<Vec<RelayRow>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT url, read, write, source FROM relays ORDER BY added_at, url")?;
        let rows = stmt.query_map([], |r| {
            Ok(RelayRow {
                url: r.get(0)?,
                read: r.get(1)?,
                write: r.get(2)?,
                source: RelaySource::parse(&r.get::<_, String>(3)?),
            })
        })?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn record_relay_connected(&self, url: &str) -> Result<()> {
        let url = relay_key(url)?;
        self.conn().execute(
            "UPDATE relays SET last_connected_at = ?2, retry_count = 0, last_error = NULL WHERE url = ?1",
            params![url, now_secs()],
        )?;
        Ok(())
    }

    pub fn record_relay_error(&self, url: &str, error: &str) -> Result<()> {
        let url = relay_key(url)?;
        self.conn().execute(
            "UPDATE relays SET last_error = ?2, retry_count = retry_count + 1 WHERE url = ?1",
            params![url, error],
        )?;
        Ok(())
    }

    /// Moves a read marker forward; never backward, so a stale marker synced
    /// from another device can't mark read messages unread again.
    pub fn mark_read(&self, scope: &str, at: i64) -> Result<()> {
        self.conn().execute(
            "INSERT INTO read_markers (scope, last_read_at) VALUES (?1, ?2)
             ON CONFLICT (scope) DO UPDATE SET last_read_at = max(last_read_at, excluded.last_read_at)",
            params![scope, at],
        )?;
        Ok(())
    }

    /// `None` means never read: a channel seen for the first time is unread.
    /// (Flutter seeded new channels as read, #62.)
    pub fn last_read(&self, scope: &str) -> Result<Option<i64>> {
        Ok(self
            .conn()
            .query_row("SELECT last_read_at FROM read_markers WHERE scope = ?1", [scope], |r| r.get(0))
            .optional()?)
    }

    pub fn read_markers(&self) -> Result<HashMap<String, i64>> {
        let conn = self.conn();
        let mut stmt = conn.prepare("SELECT scope, last_read_at FROM read_markers")?;
        let rows = stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<rusqlite::Result<_>>()?)
    }

    pub fn block(&self, pubkey_hex: &str) -> Result<()> {
        self.conn().execute(
            "INSERT INTO blocks (pubkey, blocked_at) VALUES (?1, ?2) ON CONFLICT (pubkey) DO NOTHING",
            params![pubkey_hex, now_secs()],
        )?;
        Ok(())
    }

    pub fn unblock(&self, pubkey_hex: &str) -> Result<()> {
        self.conn().execute("DELETE FROM blocks WHERE pubkey = ?1", [pubkey_hex])?;
        Ok(())
    }

    pub fn is_blocked(&self, pubkey_hex: &str) -> Result<bool> {
        Ok(self
            .conn()
            .query_row("SELECT 1 FROM blocks WHERE pubkey = ?1", [pubkey_hex], |_| Ok(()))
            .optional()?
            .is_some())
    }

    pub fn get_setting<T: DeserializeOwned>(&self, key: &str) -> Result<Option<T>> {
        let json: Option<String> = self
            .conn()
            .query_row("SELECT value FROM settings WHERE key = ?1", [key], |r| r.get(0))
            .optional()?;
        json.map(|j| serde_json::from_str(&j).map_err(|e| StoreError::Corrupt(e.to_string())))
            .transpose()
    }

    pub fn set_setting<T: Serialize>(&self, key: &str, value: &T) -> Result<()> {
        let json = serde_json::to_string(value).map_err(|e| StoreError::Corrupt(e.to_string()))?;
        self.conn().execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2)
             ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            params![key, json],
        )?;
        Ok(())
    }
}

impl Store {
    pub fn set_relay_flags(&self, url: &str, read: bool, write: bool) -> Result<()> {
        let url = relay_key(url)?;
        self.conn().execute(
            "UPDATE relays SET read = ?2, write = ?3 WHERE url = ?1",
            params![url, read, write],
        )?;
        Ok(())
    }
}
