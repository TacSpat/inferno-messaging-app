//! Forward-only schema migrations, tracked in `PRAGMA user_version`. Append to
//! `MIGRATIONS`; never edit one that has shipped.

use rusqlite::Connection;

const MIGRATIONS: &[&str] = &[
    // 1: event store and device-local state
    r#"
    CREATE TABLE events (
        id          TEXT PRIMARY KEY,
        kind        INTEGER NOT NULL,
        pubkey      TEXT NOT NULL,
        created_at  INTEGER NOT NULL,
        -- '' for replaceable kinds, the d-tag for addressable ones, NULL otherwise
        address_d   TEXT,
        json        TEXT NOT NULL,
        received_at INTEGER NOT NULL
    );
    CREATE INDEX events_kind_created ON events (kind, created_at);
    CREATE INDEX events_author_kind ON events (pubkey, kind, created_at);
    CREATE UNIQUE INDEX events_address ON events (kind, pubkey, address_d)
        WHERE address_d IS NOT NULL;

    -- Single-letter tags, for lookups like "messages in channel h=X" or
    -- "reactions to e=Y" without scanning JSON.
    CREATE TABLE event_tags (
        event_id TEXT NOT NULL REFERENCES events (id) ON DELETE CASCADE,
        name     TEXT NOT NULL,
        value    TEXT NOT NULL
    );
    CREATE INDEX event_tags_lookup ON event_tags (name, value);
    CREATE INDEX event_tags_event ON event_tags (event_id);

    -- NIP-09 deletions we've honoured. Kept after the event row is gone so a
    -- relay replaying the old copy can't resurrect it.
    CREATE TABLE deleted_events (
        event_id   TEXT PRIMARY KEY,
        deleted_by TEXT NOT NULL,
        deleted_at INTEGER NOT NULL
    );
    -- NIP-09 `a`-tag deletions: every copy of the address up to deleted_at is
    -- gone, including copies we haven't received yet. This is how a deleted
    -- server stays deleted for every member.
    CREATE TABLE deleted_addresses (
        kind       INTEGER NOT NULL,
        pubkey     TEXT NOT NULL,
        address_d  TEXT NOT NULL,
        deleted_at INTEGER NOT NULL,
        PRIMARY KEY (kind, pubkey, address_d)
    );

    CREATE TABLE relays (
        url               TEXT PRIMARY KEY,
        read              INTEGER NOT NULL DEFAULT 1,
        write             INTEGER NOT NULL DEFAULT 1,
        source            TEXT NOT NULL,
        added_at          INTEGER NOT NULL,
        last_connected_at INTEGER,
        last_error        TEXT,
        retry_count       INTEGER NOT NULL DEFAULT 0
    );

    -- Keyed by channel id or DM counterparty pubkey. Synced across devices
    -- through the kind 30078 config, merged by taking the later timestamp.
    CREATE TABLE read_markers (
        scope        TEXT PRIMARY KEY,
        last_read_at INTEGER NOT NULL
    );

    CREATE TABLE blocks (
        pubkey     TEXT PRIMARY KEY,
        blocked_at INTEGER NOT NULL
    );

    CREATE TABLE settings (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
    );
    "#,
];

pub fn run(conn: &mut Connection) -> rusqlite::Result<()> {
    let current: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(current as usize) {
        let tx = conn.transaction()?;
        tx.execute_batch(sql)?;
        tx.pragma_update(None, "user_version", (i + 1) as i64)?;
        tx.commit()?;
    }
    Ok(())
}

#[cfg(test)]
pub fn latest() -> usize {
    MIGRATIONS.len()
}
