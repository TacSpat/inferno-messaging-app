//! Cross-device config in NIP-78 (kind 30078) events, NIP-44 encrypted to
//! ourselves. Two documents, by d-tag:
//!
//! - `inferno-servers`: which servers we belong to. Flutter reads the
//!   `servers` array, so that stays; `state` adds per-server timestamps.
//! - `inferno-config`: synced settings and read markers. Flutter defined this
//!   d-tag but never published it, so its shape is ours to set.
//!
//! Flutter published whole documents, so a device with a stale copy could
//! wipe what another device had just added. Here every entry carries its own
//! timestamp and publishing always merges with the relay copy first:
//! - servers: last write wins per server (join/leave at a time);
//! - settings: last write wins per key;
//! - read markers: the later read wins, so they never move back.

use std::collections::BTreeMap;

use nostr::nips::nip44;
use nostr_sdk::prelude::*;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::kinds;
use crate::relay::RelayPool;
use crate::store::{now_secs, Store, StoreError};

pub const SERVERS_D: &str = "inferno-servers";
pub const CONFIG_D: &str = "inferno-config";

const LOCAL_SERVERS: &str = "sync.servers";
const LOCAL_SETTINGS: &str = "sync.settings";

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Relay(#[from] nostr_sdk::prelude::Error),
    #[error("could not encrypt or sign the config: {0}")]
    Build(String),
    #[error("no relay accepted the config")]
    NotPublished,
}

// ─── Documents ───────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Membership {
    pub member: bool,
    pub at: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ServerList {
    /// Server gid → latest join or leave.
    #[serde(default)]
    pub state: BTreeMap<String, Membership>,
}

impl ServerList {
    pub fn set(&mut self, gid: &str, member: bool, at: i64) {
        merge_lww(&mut self.state, gid.to_owned(), Membership { member, at }, |m| m.at);
    }

    pub fn members(&self) -> impl Iterator<Item = &str> {
        self.state.iter().filter(|(_, m)| m.member).map(|(gid, _)| gid.as_str())
    }

    pub fn merge(&mut self, other: &ServerList) {
        for (gid, m) in &other.state {
            merge_lww(&mut self.state, gid.clone(), *m, |m| m.at);
        }
    }

    /// Wire form: `servers` for Flutter, `state` for us.
    fn to_json(&self) -> Value {
        serde_json::json!({ "servers": self.members().collect::<Vec<_>>(), "state": self.state })
    }

    /// A Flutter document only has `servers`; treat each as joined when the
    /// event was published, so any explicit leave after that still wins.
    fn from_json(value: &Value, published_at: i64) -> Self {
        let mut list: ServerList = serde_json::from_value(value.clone()).unwrap_or_default();
        if let Some(servers) = value.get("servers").and_then(Value::as_array) {
            for gid in servers.iter().filter_map(Value::as_str) {
                if !list.state.contains_key(gid) {
                    list.set(gid, true, published_at);
                }
            }
        }
        list
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Setting {
    pub value: Value,
    pub at: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct ConfigDoc {
    #[serde(default)]
    pub settings: BTreeMap<String, Setting>,
    #[serde(default)]
    pub read_markers: BTreeMap<String, i64>,
}

impl ConfigDoc {
    pub fn merge(&mut self, other: &ConfigDoc) {
        for (key, s) in &other.settings {
            merge_lww(&mut self.settings, key.clone(), s.clone(), |s| s.at);
        }
        for (scope, &at) in &other.read_markers {
            let mine = self.read_markers.entry(scope.clone()).or_insert(at);
            *mine = (*mine).max(at);
        }
    }
}

/// Keeps `incoming` if it's newer than what's there. Ties keep the current
/// entry so merging is idempotent.
fn merge_lww<K: Ord, V>(map: &mut BTreeMap<K, V>, key: K, incoming: V, at: impl Fn(&V) -> i64) {
    match map.get(&key) {
        Some(current) if at(current) >= at(&incoming) => {}
        _ => {
            map.insert(key, incoming);
        }
    }
}

// ─── Encryption ──────────────────────────────────────────────────────────

/// `at` must be later than every copy already on relays: replaceable events
/// keep the newest copy, and on a same-second tie the lower id wins, which
/// could throw away the freshly merged document.
fn seal(keys: &Keys, d: &str, body: &Value, at: i64) -> Result<Event, SyncError> {
    let content = nip44::encrypt(keys.secret_key(), &keys.public_key(), body.to_string(), nip44::Version::V2)
        .map_err(|e| SyncError::Build(e.to_string()))?;
    EventBuilder::new(Kind::Custom(kinds::APP_CONFIG), content)
        .tag(Tag::identifier(d))
        .custom_created_at(Timestamp::from(at.max(0) as u64))
        .finalize(keys)
        .map_err(|e| SyncError::Build(e.to_string()))
}

/// `None` for anything that isn't ours or doesn't decrypt to JSON; a
/// corrupt copy on one relay must not break sync.
fn open(keys: &Keys, event: &Event) -> Option<Value> {
    if event.pubkey != keys.public_key() {
        return None;
    }
    let plain = nip44::decrypt(keys.secret_key(), &keys.public_key(), &event.content).ok()?;
    serde_json::from_str(&plain).ok()
}

// ─── Local state ─────────────────────────────────────────────────────────

/// Synced state as this device knows it. Changes made here are local until
/// the next [`ConfigSync::push`].
impl Store {
    pub fn synced_servers(&self) -> Result<ServerList, StoreError> {
        Ok(self.get_setting(LOCAL_SERVERS)?.unwrap_or_default())
    }

    pub fn set_server_membership(&self, gid: &str, member: bool) -> Result<(), StoreError> {
        let mut list = self.synced_servers()?;
        list.set(gid, member, now_secs());
        self.set_setting(LOCAL_SERVERS, &list)
    }

    pub fn synced_setting(&self, key: &str) -> Result<Option<Value>, StoreError> {
        let settings: BTreeMap<String, Setting> = self.get_setting(LOCAL_SETTINGS)?.unwrap_or_default();
        Ok(settings.get(key).map(|s| s.value.clone()))
    }

    pub fn set_synced_setting(&self, key: &str, value: Value) -> Result<(), StoreError> {
        let mut settings: BTreeMap<String, Setting> = self.get_setting(LOCAL_SETTINGS)?.unwrap_or_default();
        settings.insert(key.to_owned(), Setting { value, at: now_secs() });
        self.set_setting(LOCAL_SETTINGS, &settings)
    }

    fn local_config(&self) -> Result<ConfigDoc, StoreError> {
        Ok(ConfigDoc {
            settings: self.get_setting(LOCAL_SETTINGS)?.unwrap_or_default(),
            read_markers: self.read_markers()?.into_iter().collect(),
        })
    }

    fn apply_config(&self, doc: &ConfigDoc) -> Result<(), StoreError> {
        let mut settings: BTreeMap<String, Setting> = self.get_setting(LOCAL_SETTINGS)?.unwrap_or_default();
        for (key, s) in &doc.settings {
            merge_lww(&mut settings, key.clone(), s.clone(), |s| s.at);
        }
        self.set_setting(LOCAL_SETTINGS, &settings)?;
        for (scope, &at) in &doc.read_markers {
            self.mark_read(scope, at)?;
        }
        Ok(())
    }
}

// ─── Sync ────────────────────────────────────────────────────────────────

pub struct ConfigSync<'a> {
    pub keys: &'a Keys,
    pub pool: &'a RelayPool,
    pub store: &'a Store,
}

impl ConfigSync<'_> {
    fn filter(&self, d: &str) -> Filter {
        Filter::new()
            .kind(Kind::Custom(kinds::APP_CONFIG))
            .author(self.keys.public_key())
            .identifier(d)
    }

    /// Every decryptable relay copy of `d`, so a stale copy on one relay
    /// can't hide a newer one elsewhere; merging makes order irrelevant.
    async fn fetch(&self, d: &str) -> Result<Vec<(Value, i64)>, SyncError> {
        let events = self.pool.client().fetch_events(vec![self.filter(d)]).await?;
        Ok(events
            .iter()
            .filter_map(|e| Some((open(self.keys, e)?, e.created_at.as_secs() as i64)))
            .collect())
    }

    /// Merges what relays have into local state.
    pub async fn pull(&self) -> Result<(), SyncError> {
        self.pull_inner().await.map(|_| ())
    }

    /// Returns the newest relay copy's `created_at`, or 0 if there's none.
    async fn pull_inner(&self) -> Result<i64, SyncError> {
        let mut newest = 0;
        let mut servers = self.store.synced_servers()?;
        for (doc, at) in self.fetch(SERVERS_D).await? {
            servers.merge(&ServerList::from_json(&doc, at));
            newest = newest.max(at);
        }
        self.store.set_setting(LOCAL_SERVERS, &servers)?;

        for (doc, at) in self.fetch(CONFIG_D).await? {
            newest = newest.max(at);
            if let Ok(remote) = serde_json::from_value::<ConfigDoc>(doc) {
                self.store.apply_config(&remote)?;
            }
        }
        Ok(newest)
    }

    /// Pulls, then publishes the merged result, so nothing another device
    /// added since our last pull is overwritten.
    pub async fn push(&self) -> Result<(), SyncError> {
        let at = now_secs().max(self.pull_inner().await? + 1);
        let servers = self.store.synced_servers()?;
        let config = self.store.local_config()?;
        let config_json = serde_json::to_value(&config).map_err(|e| SyncError::Build(e.to_string()))?;
        for event in [
            seal(self.keys, SERVERS_D, &servers.to_json(), at)?,
            seal(self.keys, CONFIG_D, &config_json, at)?,
        ] {
            if !self.pool.publish(&event).await?.any_accepted() {
                return Err(SyncError::NotPublished);
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests;
