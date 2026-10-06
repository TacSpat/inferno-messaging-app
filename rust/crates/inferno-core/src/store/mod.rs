//! Local SQLite cache. Raw Nostr events are the source of truth (`events`);
//! everything the UI reads is derived from them or is device-local state.
//!
//! Lessons carried over from the Flutter/Drift build:
//! - Replaceable and addressable events keep only the newest copy per address,
//!   enforced here at write time, so a stale relay copy can't revert state.
//! - Deleted events (NIP-09) are remembered, so a relay that still has a copy
//!   can't bring a deleted server or message back.
//! - Upserts use SQLite's own `ON CONFLICT ... DO UPDATE`, which works on any
//!   unique index (Drift's helper only handled the primary key).

pub(crate) mod events;
mod dms;
mod local;
mod migrations;

use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use rusqlite::Connection;

pub use events::PutOutcome;
pub use local::{RelayRow, RelaySource};

#[derive(Debug, thiserror::Error)]
pub enum StoreError {
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error("not a relay URL: {0}")]
    InvalidRelayUrl(String),
    #[error("stored event is corrupt: {0}")]
    Corrupt(String),
}

pub type Result<T> = std::result::Result<T, StoreError>;

/// One connection behind a mutex. Calls are short and synchronous; callers on
/// an async runtime should use `spawn_blocking` for anything bulk.
pub struct Store {
    conn: Mutex<Connection>,
}

impl Store {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        Self::init(Connection::open(path)?)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(mut conn: Connection) -> Result<Self> {
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "foreign_keys", true)?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        migrations::run(&mut conn)?;
        Ok(Self { conn: Mutex::new(conn) })
    }

    /// A consistent copy of the whole cache in a new file (SQLite's
    /// VACUUM INTO): for backups, and for tests that restart from a cache.
    pub fn snapshot_to(&self, path: &Path) -> Result<()> {
        self.conn().execute("VACUUM INTO ?1", [path.to_string_lossy()])?;
        Ok(())
    }

    pub(crate) fn conn(&self) -> MutexGuard<'_, Connection> {
        // A panic mid-call leaves SQLite itself consistent (the transaction
        // rolls back), so a poisoned lock is safe to keep using.
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }
}

pub fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests;
