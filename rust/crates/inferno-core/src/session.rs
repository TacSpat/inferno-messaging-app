//! A signed-in client: relays, cache, sync and live subscriptions tied
//! together. The UI holds one `Session`, reads resolved state from it, and
//! listens on [`Session::updates`] to know what to redraw.
//!
//! Every incoming event goes into the cache first; state is always resolved
//! from the cache, so a restart shows the same thing a live session did.

use std::collections::{HashMap, HashSet};

#[derive(Debug, Clone)]
pub struct SearchHit {
    pub channel_id: String,
    pub channel_name: String,
    pub message: ChannelMessage,
}

/// What `Session::create_channel` makes.
#[derive(Debug, Clone, Default)]
pub struct ChannelSpec {
    pub name: String,
    pub voice: bool,
    pub category: Option<String>,
    pub topic: String,
    pub encrypted: bool,
    /// For encrypted channels: roles allowed in besides owner and admins.
    pub allowed_roles: Vec<String>,
    pub post_only: bool,
    pub nsfw: bool,
}
use std::sync::{Arc, Mutex};

use nostr_sdk::prelude::*;
use tokio::sync::broadcast;

use crate::channel::send::{self, Outgoing, SendError};
use crate::channel::{keys as channel_keys, ChannelKeys, ChannelMessage, Timeline};
use crate::dm::{self, IncomingDm};
use crate::relay::{PublishReport, RelayPool};
use crate::server::invite_link::{self, InviteLink};
use crate::server::publish::{self, PublishError};
use crate::server::{order, wire, Permission, ServerState};
use crate::store::{now_secs, Store, StoreError};
use crate::sync::{config::ConfigSync, profile::{self, ProfileUpdate}, relays};
use crate::{dtag, kinds};

const CHANNEL_KINDS: [u16; 4] = [kinds::CHANNEL_MESSAGE, kinds::CHANNEL_DELETE, kinds::PIN, kinds::REACTION];
const TIMELINE_LIMIT: usize = 5_000;

#[derive(Debug, Clone)]
pub enum Update {
    /// Server state changed (metadata, structure, roles, members, ...).
    Server(String),
    /// Something in this channel's timeline changed.
    Channel { gid: String, channel_id: String },
    Dm(IncomingDm),
}

#[derive(Debug, thiserror::Error)]
pub enum SessionError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Relay(#[from] nostr_sdk::prelude::Error),
    #[error(transparent)]
    Publish(#[from] PublishError),
    #[error(transparent)]
    Send(#[from] SendError),
    #[error("not a valid invite link")]
    BadInvite,
    #[error("unknown server or channel")]
    Unknown,
    #[error("no relay accepted the event")]
    NotPublished,
    #[error("{0}")]
    Other(String),
}

pub type Result<T> = std::result::Result<T, SessionError>;

pub struct Session {
    keys: Keys,
    store: Arc<Store>,
    pool: Arc<RelayPool>,
    updates: broadcast::Sender<Update>,
    /// Channel keys we hold, per server.
    channel_keys: Mutex<HashMap<String, ChannelKeys>>,
    /// `h` group id → (gid, channel id), for routing channel traffic.
    groups: Mutex<HashMap<String, (String, String)>>,
    /// Fixed for the session so the member subscription's filter is stable
    /// (a fresh `now` each time would defeat the no-op re-subscribe).
    started_at: Timestamp,
    /// Wakes the background task that batches resubscribes and key rebuilds.
    refresh: Arc<tokio::sync::Notify>,
    /// Wakes the background task that debounces config pushes.
    config_dirty: Arc<tokio::sync::Notify>,
}

impl Drop for Session {
    /// Wakes the batchers so they notice the session is gone and exit.
    fn drop(&mut self) {
        self.refresh.notify_one();
        self.config_dirty.notify_one();
    }
}

/// How long state changes are batched before refreshing subscriptions, and
/// how long config changes settle before one push (Flutter used 5s).
const REFRESH_SETTLE: std::time::Duration = std::time::Duration::from_millis(500);
const CONFIG_SETTLE: std::time::Duration = std::time::Duration::from_secs(5);
/// Messages fetched for a server's channels when we first join it.
const JOIN_BACKFILL: usize = 500;
/// Overlap when resuming a subscription from the newest cached event, for
/// clock skew between relays.
const RESUME_OVERLAP_SECS: u64 = 60;

#[derive(Debug, Clone)]
pub struct StartOptions {
    /// Add the default public relays if missing. Off for tests and for
    /// private deployments that configure their own relays.
    pub seed_default_relays: bool,
}

impl Default for StartOptions {
    fn default() -> Self {
        Self { seed_default_relays: true }
    }
}

impl Session {
    /// Connects, catches up on relay lists and config, and starts listening.
    pub async fn start(keys: Keys, store: Store) -> Result<Arc<Self>> {
        Self::start_with(keys, store, StartOptions::default()).await
    }

    pub async fn start_with(keys: Keys, store: Store, options: StartOptions) -> Result<Arc<Self>> {
        let store = Arc::new(store);
        if options.seed_default_relays {
            store.seed_default_relays()?;
        }
        let pool = Arc::new(RelayPool::new(keys.clone()));
        pool.add_relays(store.relays()?.iter().map(|r| r.url.clone())).await?;
        pool.connect().await;

        // Best effort: an unreachable relay list or config isn't fatal.
        if let Err(e) = relays::pull(&pool, &store, &keys).await {
            tracing::warn!("relay list pull failed: {e}");
        }
        pool.add_relays(store.relays()?.iter().map(|r| r.url.clone())).await?;
        pool.connect().await;
        if let Err(e) = (ConfigSync { keys: &keys, pool: &pool, store: &store }).pull().await {
            tracing::warn!("config pull failed: {e}");
        }
        // Our own profile, so the UI shows what other devices last set.
        match pool.fetch(vec![Filter::new().kind(Kind::Metadata).author(keys.public_key())]).await {
            Ok(events) => {
                for e in &events {
                    store.put_event(e)?;
                }
            }
            Err(e) => tracing::warn!("profile fetch failed: {e}"),
        }

        let (updates, _) = broadcast::channel(1024);
        let session = Arc::new(Session {
            keys,
            store,
            pool,
            updates,
            channel_keys: Mutex::new(HashMap::new()),
            groups: Mutex::new(HashMap::new()),
            started_at: Timestamp::now(),
            refresh: Arc::new(tokio::sync::Notify::new()),
            config_dirty: Arc::new(tokio::sync::Notify::new()),
        });
        session.rebuild_channel_keys()?;
        session.resubscribe().await?;
        session.spawn_listener();
        session.spawn_batchers();
        Ok(session)
    }

    pub fn keys(&self) -> &Keys {
        &self.keys
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn updates(&self) -> broadcast::Receiver<Update> {
        self.updates.subscribe()
    }

    pub fn servers(&self) -> Result<Vec<String>> {
        Ok(self.store.synced_servers()?.members().map(str::to_owned).collect())
    }

    pub fn server(&self, gid: &str) -> Result<Option<ServerState>> {
        Ok(self.store.load_server(gid)?)
    }

    pub fn timeline(&self, gid: &str, channel_id: &str) -> Result<Vec<ChannelMessage>> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let channel = state.channel(channel_id).ok_or(SessionError::Unknown)?;
        let Some(group) = channel.group_id.as_deref() else { return Ok(Vec::new()) };
        let mut events = Vec::new();
        for kind in CHANNEL_KINDS {
            events.extend(self.store.events_by_tag(Kind::Custom(kind), 'h', group, TIMELINE_LIMIT)?);
        }
        let blocked: HashSet<PublicKey> = self.blocked()?;
        let keys = self.channel_keys.lock().unwrap_or_else(|e| e.into_inner());
        let empty = ChannelKeys::default();
        let ck = keys.get(gid).unwrap_or(&empty);
        Ok(Timeline::resolve(&state, channel, &events, ck, &blocked))
    }

    fn blocked(&self) -> Result<HashSet<PublicKey>> {
        // Blocks are few; reading them per timeline keeps them always fresh.
        let conn_blocked = self.store.blocked_pubkeys()?;
        Ok(conn_blocked.iter().filter_map(|h| PublicKey::from_hex(h).ok()).collect())
    }

    // ─── Actions ─────────────────────────────────────────────────────────

    /// A replaceable event must be newer than our previous copy, or relays
    /// (and our own cache) keep the old one: two edits in the same second
    /// otherwise lose the second about half the time.
    fn fresh(&self, event: Event) -> Result<Event> {
        let d = if event.kind.is_addressable() {
            event.tags.identifier().unwrap_or_default()
        } else if event.kind.is_replaceable() {
            String::new()
        } else {
            return Ok(event);
        };
        let Some(prev) = self.store.get_addressable(event.kind, &event.pubkey, &d)? else { return Ok(event) };
        if prev.created_at < event.created_at {
            return Ok(event);
        }
        EventBuilder::new(event.kind, event.content.clone())
            .tags(event.tags.clone())
            .custom_created_at(crate::sync::publish_time(Some(prev.created_at)))
            .finalize(&self.keys)
            .map_err(|e| SessionError::Other(e.to_string()))
    }

    async fn publish(&self, event: &Event) -> Result<PublishReport> {
        let event = &self.fresh(event.clone())?;
        self.store.put_event(event)?;
        let report = self.pool.publish(event).await?;
        if !report.any_accepted() {
            tracing::warn!("rejected {}: {:?}", event.id, report.rejected);
            return Err(SessionError::NotPublished);
        }
        Ok(report)
    }

    /// Queues a config push; changes within a few seconds go out as one.
    fn push_config(&self) {
        self.config_dirty.notify_one();
    }

    /// Sets a setting that follows the user across devices (kind 30078),
    /// pushed with the next debounced config push.
    pub fn set_synced_setting(&self, key: &str, value: serde_json::Value) -> Result<()> {
        self.store.set_synced_setting(key, value)?;
        self.push_config();
        Ok(())
    }

    pub fn synced_setting(&self, key: &str) -> Result<Option<serde_json::Value>> {
        Ok(self.store.synced_setting(key)?)
    }

    /// Pushes queued config now (e.g. before shutting down).
    pub async fn flush_config(&self) {
        if let Err(e) = (ConfigSync { keys: &self.keys, pool: &self.pool, store: &self.store }).push().await {
            tracing::warn!("config push failed: {e}");
        }
    }

    fn spawn_batchers(self: &Arc<Self>) {
        let (me, refresh) = (Arc::downgrade(self), self.refresh.clone());
        tokio::spawn(async move {
            loop {
                refresh.notified().await;
                tokio::time::sleep(REFRESH_SETTLE).await;
                let Some(s) = me.upgrade() else { break };
                if let Err(e) = s.resubscribe().await {
                    tracing::warn!("resubscribe failed: {e}");
                }
                if let Err(e) = s.rebuild_channel_keys() {
                    tracing::warn!("channel key rebuild failed: {e}");
                }
            }
        });
        let (me, dirty) = (Arc::downgrade(self), self.config_dirty.clone());
        tokio::spawn(async move {
            loop {
                dirty.notified().await;
                // Keep waiting while changes keep coming.
                while tokio::time::timeout(CONFIG_SETTLE, dirty.notified()).await.is_ok() {
                    if me.strong_count() == 0 {
                        return;
                    }
                }
                let Some(s) = me.upgrade() else { break };
                s.flush_config().await;
            }
        });
    }

    pub async fn create_server(&self, name: &str) -> Result<String> {
        let (gid, events) = publish::create_server(&self.keys, name)?;
        self.store.pin_server_owner(&gid, &self.keys.public_key())?;
        for e in &events {
            self.publish(e).await?;
        }
        self.store.set_server_membership(&gid, true)?;
        self.push_config();
        self.resubscribe().await?;
        let _ = self.updates.send(Update::Server(gid.clone()));
        Ok(gid)
    }

    /// Publishes an invite and returns its `nostr:naddr1…` link.
    pub async fn create_invite(&self, gid: &str) -> Result<String> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let code = publish::new_public_id()[..8].to_owned();
        self.publish(&publish::invite(&self.keys, &state, &code, 0, 0)?).await?;
        invite_link::encode(gid, &code, &self.keys.public_key(), &[]).ok_or(SessionError::Unknown)
    }

    pub async fn join(&self, link: &str) -> Result<String> {
        let link: InviteLink = invite_link::parse(link).ok_or(SessionError::BadInvite)?;
        if !link.relays.is_empty() {
            self.pool.add_relays(&link.relays).await?;
            self.pool.connect().await;
        }
        let events = self.fetch_server(&link.gid).await?;
        let owner = invite_link::resolve_owner(&link, &events);
        self.store.pin_server_owner(&link.gid, &owner)?;

        let state = self.server(&link.gid)?.ok_or(SessionError::Unknown)?;
        // max_uses isn't checked: without a server counting uses, nothing
        // trustworthy says how many times an invite has been used.
        // The invite must be on record (not revoked) from the link's author.
        let invite_ok = state.invites.get(&link.code).is_some_and(|i| {
            i.created_by == link.author && (i.expires_at == 0 || i.expires_at > now_secs())
        });
        if !invite_ok || state.is_banned(&self.keys.public_key()) {
            return Err(SessionError::BadInvite);
        }

        let me = profile::member_profile(&self.my_profile()?);
        self.publish(&publish::join(&self.keys, &link.gid, "", &me, now_secs())?).await?;
        self.store.set_server_membership(&link.gid, true)?;
        self.push_config();
        self.backfill(&state).await?;
        self.resubscribe().await?;
        let _ = self.updates.send(Update::Server(link.gid.clone()));
        Ok(link.gid)
    }

    pub async fn leave(&self, gid: &str) -> Result<()> {
        self.publish(&publish::leave(&self.keys, gid)?).await?;
        self.store.set_server_membership(gid, false)?;
        self.push_config();
        self.resubscribe().await?;
        Ok(())
    }

    /// Publishes a changed structure (needs manage_channels).
    async fn publish_structure(&self, gid: &str, structure: &wire::Structure) -> Result<Event> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let event = self.fresh(publish::structure(&self.keys, &state, structure)?)?;
        self.store.put_event(&event)?;
        if !self.pool.publish(&event).await?.any_accepted() {
            return Err(SessionError::NotPublished);
        }
        Ok(event)
    }

    async fn after_structure_change(&self, gid: &str) -> Result<()> {
        self.resubscribe().await?;
        let _ = self.updates.send(Update::Server(gid.into()));
        Ok(())
    }

    /// Adds a channel. For an encrypted one, the key is generated, announced
    /// in the structure and shared with every reader before the structure is
    /// published, so nobody can send to it before it has a key.
    pub async fn create_channel(&self, gid: &str, spec: &ChannelSpec) -> Result<String> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let id = publish::new_public_id();
        let key = spec.encrypted.then(channel_keys::generate);
        let mut overrides = serde_json::Map::new();
        if spec.encrypted && !spec.allowed_roles.is_empty() {
            overrides.insert("allowed_role_ids".into(), serde_json::json!(spec.allowed_roles));
        }
        let channel = wire::Channel {
            group_id: Some(publish::channel_group_id(gid, &id)),
            id: id.clone(),
            name: spec.name.trim().to_owned(),
            kind: if spec.voice { "voice".into() } else { "text".into() },
            position: 0,
            category: spec.category.clone(),
            topic: spec.topic.clone(),
            nsfw: spec.nsfw,
            permission_overrides: overrides,
            encrypted: spec.encrypted,
            channel_pubkey: key.as_ref().map(|k| k.public_key().to_hex()),
            sidechat: None,
            parent: None,
            voice_bitrate: 64_000,
            voice_user_limit: 0,
            video_enabled: false,
            post_only: spec.post_only,
        };
        let mut structure = state.structure.clone();
        structure.channels.push(channel.clone());
        // New channels go to the end of their category; at the top level,
        // after the other uncategorized channels but before the first
        // category, or they'd look like they belong to it.
        let index = match spec.category {
            Some(_) => usize::MAX,
            None => order::root_items(&state.structure)
                .iter()
                .position(|i| matches!(i, order::RootItem::Category(_)))
                .unwrap_or(usize::MAX),
        };
        order::move_channel(&mut structure, &id, spec.category.as_deref(), index);

        if let Some(key) = key {
            // Readers as the new structure will define them.
            let preview = ServerState { structure: structure.clone(), ..state.clone() };
            let channel = preview.channel(&id).cloned().ok_or(SessionError::Unknown)?;
            let wraps = channel_keys::share(&self.keys, gid, &id, &key, channel_keys::readers(&preview, &channel))
                .map_err(SessionError::Other)?;
            for w in &wraps {
                self.pool.publish(w).await?;
            }
            self.channel_keys.lock().unwrap_or_else(|e| e.into_inner()).entry(gid.into()).or_default().insert(key);
        }
        self.publish_structure(gid, &structure).await?;
        self.after_structure_change(gid).await?;
        Ok(id)
    }

    pub async fn create_category(&self, gid: &str, name: &str) -> Result<String> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let id = publish::new_public_id();
        let mut structure = state.structure.clone();
        structure.categories.push(wire::Category { id: id.clone(), name: name.trim().to_owned(), position: i64::MAX });
        let last = order::root_items(&structure).len();
        order::move_category(&mut structure, &id, last);
        self.publish_structure(gid, &structure).await?;
        self.after_structure_change(gid).await?;
        Ok(id)
    }

    /// Renames, re-topics or otherwise edits a channel in place. If an
    /// encrypted channel gains readers, they're sent its current key.
    pub async fn update_channel(&self, gid: &str, id: &str, edit: impl FnOnce(&mut wire::Channel)) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let mut structure = state.structure.clone();
        let channel = structure.channels.iter_mut().find(|c| c.id == id).ok_or(SessionError::Unknown)?;
        let before = channel.clone();
        edit(channel);
        // The key, the group and the id aren't editable here.
        channel.id = before.id.clone();
        channel.group_id = before.group_id.clone();
        channel.encrypted = before.encrypted;
        channel.channel_pubkey = before.channel_pubkey.clone();
        let after = channel.clone();
        self.publish_structure(gid, &structure).await?;

        if after.encrypted {
            let old: HashSet<PublicKey> = channel_keys::readers(&state, &before).into_iter().collect();
            let new_state = self.server(gid)?.ok_or(SessionError::Unknown)?;
            let added: Vec<PublicKey> =
                channel_keys::readers(&new_state, &after).into_iter().filter(|p| !old.contains(p)).collect();
            let key = after.channel_pubkey.as_deref().and_then(|pk| {
                self.channel_keys.lock().unwrap_or_else(|e| e.into_inner()).get(gid).and_then(|k| k.get(pk).cloned())
            });
            if let (Some(key), false) = (key, added.is_empty()) {
                for w in channel_keys::share(&self.keys, gid, id, &key, added).map_err(SessionError::Other)? {
                    self.pool.publish(&w).await?;
                }
            }
        }
        self.after_structure_change(gid).await
    }

    pub async fn rename_category(&self, gid: &str, id: &str, name: &str) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let mut structure = state.structure.clone();
        let cat = structure.categories.iter_mut().find(|c| c.id == id).ok_or(SessionError::Unknown)?;
        cat.name = name.trim().to_owned();
        self.publish_structure(gid, &structure).await?;
        self.after_structure_change(gid).await
    }

    /// Removes a channel from the structure. Its messages stay on relays but
    /// no client shows a channel that isn't in the structure.
    pub async fn delete_channel(&self, gid: &str, id: &str) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let mut structure = state.structure.clone();
        let before = structure.channels.len();
        structure.channels.retain(|c| c.id != id);
        if structure.channels.len() == before {
            return Err(SessionError::Unknown);
        }
        self.publish_structure(gid, &structure).await?;
        self.after_structure_change(gid).await
    }

    /// Deletes a category; its channels move to the root, keeping order.
    pub async fn delete_category(&self, gid: &str, id: &str) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let mut structure = state.structure.clone();
        for ch in order::in_category(&structure, id) {
            order::move_channel(&mut structure, &ch, None, usize::MAX);
        }
        structure.categories.retain(|c| c.id != id);
        self.publish_structure(gid, &structure).await?;
        self.after_structure_change(gid).await
    }

    /// Moves a channel to `index` within `category` (`None` = root).
    pub async fn move_channel(&self, gid: &str, id: &str, category: Option<&str>, index: usize) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let mut structure = state.structure.clone();
        if !order::move_channel(&mut structure, id, category, index) {
            return Err(SessionError::Unknown);
        }
        self.publish_structure(gid, &structure).await?;
        self.after_structure_change(gid).await
    }

    pub async fn move_category(&self, gid: &str, id: &str, index: usize) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let mut structure = state.structure.clone();
        if !order::move_category(&mut structure, id, index) {
            return Err(SessionError::Unknown);
        }
        self.publish_structure(gid, &structure).await?;
        self.after_structure_change(gid).await
    }

    // ─── Search ─────────────────────────────────────────────────────────

    /// Searches the cached messages of every channel in `gid` we can read.
    /// Newest first, at most `limit`.
    pub fn search(&self, gid: &str, query: &crate::search::Query, limit: usize) -> Result<Vec<SearchHit>> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let me = self.keys.public_key();
        let names = |pk: &PublicKey| -> Vec<String> {
            let mut v = vec![pk.to_hex()];
            let Ok(npub) = nostr::nips::nip19::ToBech32::to_bech32(pk);
            v.push(npub);
            if let Some(m) = state.members.get(pk) {
                v.extend(m.nickname.clone());
                v.push(m.profile.display_name.clone());
                v.push(m.profile.name.clone());
            }
            v.retain(|n| !n.is_empty());
            v
        };
        let mut hits = Vec::new();
        for channel in state.structure.channels.iter().filter(|c| c.kind != "voice" && state.can_read(&me, c)) {
            if !query.in_channels.is_empty() && !query.in_channels.contains(&channel.name.to_lowercase()) {
                continue;
            }
            for m in self.timeline(gid, &channel.id)? {
                let Some(body) = m.content.as_deref() else { continue };
                if query.matches(body, m.created_at, m.pinned, &names(&m.author), &channel.name) {
                    hits.push(SearchHit { channel_id: channel.id.clone(), channel_name: channel.name.clone(), message: m });
                }
            }
        }
        hits.sort_by_key(|h| std::cmp::Reverse((h.message.created_at, h.message.id)));
        hits.truncate(limit);
        Ok(hits)
    }

    // ─── Server settings ────────────────────────────────────────────────

    /// Edits the server's metadata (needs manage_server).
    pub async fn update_metadata(&self, gid: &str, edit: impl FnOnce(&mut wire::Metadata)) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let mut meta = state.metadata.clone();
        edit(&mut meta);
        self.publish(&publish::metadata(&self.keys, &state, &meta)?).await?;
        let _ = self.updates.send(Update::Server(gid.into()));
        Ok(())
    }

    /// Deletes the server for everyone (owner only): metadata marked
    /// `deleted` (what Rails reads) plus a NIP-09 deletion of the server's
    /// state addresses, so relays and every member's client drop it.
    /// Flutter only deleted it locally.
    pub async fn delete_server(&self, gid: &str) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        if !state.is_owner(&self.keys.public_key()) {
            return Err(SessionError::Other("only the owner can delete the server".into()));
        }
        let mut meta = state.metadata.clone();
        meta.deleted = true;
        self.publish(&publish::metadata(&self.keys, &state, &meta)?).await?;
        let me = self.keys.public_key();
        let coords = [
            (kinds::SERVER_STRUCTURE, dtag::structure(gid)),
            (kinds::SERVER_ROLES, dtag::roles(gid)),
            (kinds::SERVER_EMOJI, dtag::emojis(gid)),
            (kinds::SERVER_STICKERS, dtag::stickers(gid)),
        ]
        .into_iter()
        .map(|(k, d)| Tag::coordinate(Coordinate::new(Kind::Custom(k), me).identifier(d), None));
        let deletion = EventBuilder::new(Kind::EventDeletion, "server deleted")
            .tags(coords)
            .finalize(&self.keys)
            .map_err(|e| SessionError::Other(e.to_string()))?;
        self.publish(&deletion).await?;
        self.store.set_server_membership(gid, false)?;
        self.push_config();
        self.resubscribe().await?;
        let _ = self.updates.send(Update::Server(gid.into()));
        Ok(())
    }

    /// Replaces the role list (needs manage_roles). Keeps `@everyone`.
    pub async fn save_roles(&self, gid: &str, roles: Vec<wire::Role>) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        if !roles.iter().any(|r| r.is_everyone()) {
            return Err(SessionError::Other("the @everyone role can't be removed".into()));
        }
        self.publish(&publish::roles(&self.keys, &state, &roles)?).await?;
        let _ = self.updates.send(Update::Server(gid.into()));
        Ok(())
    }

    pub async fn set_member_roles(&self, gid: &str, member: &PublicKey, role_ids: &[String]) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        self.publish(&publish::set_roles(&self.keys, &state, member, role_ids)?).await?;
        let _ = self.updates.send(Update::Server(gid.into()));
        Ok(())
    }

    pub async fn kick(&self, gid: &str, member: &PublicKey) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        self.publish(&publish::kick(&self.keys, &state, member)?).await?;
        let _ = self.updates.send(Update::Server(gid.into()));
        Ok(())
    }

    /// `until` = 0 lifts the timeout.
    pub async fn timeout(&self, gid: &str, member: &PublicKey, until: i64) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        self.publish(&publish::timeout(&self.keys, &state, member, until)?).await?;
        let _ = self.updates.send(Update::Server(gid.into()));
        Ok(())
    }

    pub async fn ban(&self, gid: &str, member: &PublicKey, reason: &str) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        self.publish(&publish::ban(&self.keys, &state, member, reason)?).await?;
        let _ = self.updates.send(Update::Server(gid.into()));
        Ok(())
    }

    pub async fn unban(&self, gid: &str, member: &PublicKey) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        self.publish(&publish::unban(&self.keys, &state, member)?).await?;
        let _ = self.updates.send(Update::Server(gid.into()));
        Ok(())
    }

    /// Shares the current keys of `gid`'s encrypted channels that `member`
    /// may read. Managers' sessions do this when someone joins.
    async fn share_keys_with(&self, gid: &str, member: PublicKey) -> Result<()> {
        let Some(state) = self.server(gid)? else { return Ok(()) };
        if !state.has(&self.keys.public_key(), Permission::ManageChannels)
            || !state.has(&member, Permission::ReadMessages)
        {
            return Ok(());
        }
        let mut wraps = Vec::new();
        {
            let all = self.channel_keys.lock().unwrap_or_else(|e| e.into_inner());
            let Some(held) = all.get(gid) else { return Ok(()) };
            for c in state.structure.channels.iter().filter(|c| c.encrypted && state.can_read(&member, c)) {
                let Some(key) = c.channel_pubkey.as_deref().and_then(|pk| held.get(pk)) else { continue };
                wraps.extend(channel_keys::share(&self.keys, gid, &c.id, key, [member]).map_err(SessionError::Other)?);
            }
        }
        for w in &wraps {
            self.pool.publish(w).await?;
        }
        Ok(())
    }

    pub async fn send(&self, gid: &str, channel_id: &str, msg: &Outgoing<'_>) -> Result<Event> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let channel = state.channel(channel_id).ok_or(SessionError::Unknown)?;
        let event = send::message(&self.keys, &state, channel, msg, now_secs())?;
        self.publish(&event).await?;
        let _ = self.updates.send(Update::Channel { gid: gid.into(), channel_id: channel_id.into() });
        Ok(event)
    }

    /// Our current kind 0 profile (empty if we never set one).
    pub fn my_profile(&self) -> Result<serde_json::Map<String, serde_json::Value>> {
        Ok(self
            .store
            .get_addressable(Kind::Metadata, &self.keys.public_key(), "")?
            .map(|e| profile::content(&e))
            .unwrap_or_default())
    }

    /// Publishes a profile change: kind 0, then our member event in every
    /// server we still belong to, since Rails reads profiles from those.
    /// Servers we were kicked from are skipped: a newer self-signed member
    /// event would undo the kick.
    pub async fn update_profile(&self, update: &ProfileUpdate) -> Result<()> {
        profile::update(&self.pool, &self.store, &self.keys, update)
            .await
            .map_err(|e| SessionError::Other(e.to_string()))?;
        let me_profile = profile::member_profile(&self.my_profile()?);
        let me = self.keys.public_key();
        for gid in self.servers()? {
            let Some(state) = self.server(&gid)? else { continue };
            let Some(member) = state.members.get(&me).cloned() else {
                // The owner of a server made here has no member event yet.
                if state.is_owner(&me) {
                    self.publish(&publish::join(&self.keys, &gid, "", &me_profile, now_secs())?).await?;
                }
                continue;
            };
            let nickname = member.nickname.clone().unwrap_or_default();
            let joined = member.joined_at.unwrap_or_else(now_secs);
            self.publish(&publish::join(&self.keys, &gid, &nickname, &me_profile, joined)?).await?;
            let _ = self.updates.send(Update::Server(gid));
        }
        Ok(())
    }

    pub fn relays(&self) -> Result<Vec<crate::store::RelayRow>> {
        Ok(self.store.relays()?)
    }

    /// Adds a relay here, connects to it, and shares the list (NIP-65).
    pub async fn add_relay(&self, url: &str) -> Result<()> {
        self.store.add_relay(url, crate::store::RelaySource::User)?;
        let url = crate::relay::normalize_url(url).ok_or(SessionError::Other("not a relay URL".into()))?;
        self.pool.add_relays([url]).await?;
        self.pool.connect().await;
        self.push_relays().await;
        Ok(())
    }

    pub async fn remove_relay(&self, url: &str) -> Result<()> {
        self.store.remove_relay(url)?;
        if let Some(url) = crate::relay::normalize_url(url) {
            let _ = self.pool.client().remove_relay(url.as_str()).await;
        }
        self.push_relays().await;
        Ok(())
    }

    async fn push_relays(&self) {
        if let Err(e) = relays::push(&self.pool, &self.store, &self.keys).await {
            tracing::warn!("relay list push failed: {e}");
        }
    }

    /// Edits one of our messages. Only the author's edits count, so this
    /// refuses anyone else's.
    pub async fn edit(&self, gid: &str, channel_id: &str, original: EventId, text: &str) -> Result<Event> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let channel = state.channel(channel_id).ok_or(SessionError::Unknown)?;
        let original = self.store.get_event(&original)?.ok_or(SessionError::Unknown)?;
        let event = send::edit(&self.keys, &state, channel, &original, text, now_secs())?;
        self.publish(&event).await?;
        let _ = self.updates.send(Update::Channel { gid: gid.into(), channel_id: channel_id.into() });
        Ok(event)
    }

    /// Deletes a message (ours, or anyone's with manage_messages).
    pub async fn delete_message(&self, gid: &str, channel_id: &str, target: EventId) -> Result<Event> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let channel = state.channel(channel_id).ok_or(SessionError::Unknown)?;
        let original = self.store.get_event(&target)?.ok_or(SessionError::Unknown)?;
        let event = send::delete(&self.keys, &state, channel, &original)?;
        self.publish(&event).await?;
        let _ = self.updates.send(Update::Channel { gid: gid.into(), channel_id: channel_id.into() });
        Ok(event)
    }

    /// Pins or unpins a message (needs manage_messages).
    pub async fn pin(&self, gid: &str, channel_id: &str, target: EventId, pinned: bool) -> Result<Event> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let channel = state.channel(channel_id).ok_or(SessionError::Unknown)?;
        let event = send::pin(&self.keys, &state, channel, target, pinned)?;
        self.publish(&event).await?;
        let _ = self.updates.send(Update::Channel { gid: gid.into(), channel_id: channel_id.into() });
        Ok(event)
    }

    pub async fn send_dm(&self, to: PublicKey, body: &str) -> Result<()> {
        let events = dm::build(&self.keys, to, body, vec![]).map_err(|e| SessionError::Other(e.to_string()))?;
        for e in &events {
            self.pool.publish(e).await?;
        }
        Ok(())
    }

    // ─── Subscriptions ───────────────────────────────────────────────────

    async fn fetch_server(&self, gid: &str) -> Result<Vec<Event>> {
        let exact = vec![dtag::metadata(gid), dtag::structure(gid), dtag::roles(gid), dtag::emojis(gid), dtag::stickers(gid)];
        let state_kinds = [kinds::SERVER_METADATA, kinds::SERVER_STRUCTURE, kinds::SERVER_ROLES, kinds::SERVER_EMOJI, kinds::SERVER_STICKERS];
        let events = self
            .pool
            .fetch(vec![
                Filter::new().kinds(state_kinds.map(Kind::Custom)).identifiers(exact),
                // Relays can't match a d-tag prefix; filter these locally.
                Filter::new().kinds([kinds::SERVER_MEMBER, kinds::SERVER_BAN, kinds::SERVER_INVITE].map(Kind::Custom)),
            ])
            .await?;
        let mut kept = Vec::new();
        for e in events {
            if wire::server_gid(&e).as_deref() == Some(gid) {
                self.store.put_event(&e)?;
                kept.push(e);
            }
        }
        Ok(kept)
    }

    /// One bounded fetch of recent history for a server we just joined; the
    /// live subscription only covers what's new from here on.
    async fn backfill(&self, state: &ServerState) -> Result<()> {
        let groups: Vec<String> = state.structure.channels.iter().filter_map(|c| c.group_id.clone()).collect();
        if groups.is_empty() {
            return Ok(());
        }
        let filter = Filter::new()
            .kinds(CHANNEL_KINDS.map(Kind::Custom))
            .custom_tags(SingleLetterTag::from_char('h').expect("h"), groups)
            .limit(JOIN_BACKFILL);
        for e in self.pool.fetch(vec![filter]).await? {
            self.store.put_event(&e)?;
        }
        Ok(())
    }

    fn resume_from(&self, newest: Option<i64>) -> Option<Timestamp> {
        newest.map(|at| Timestamp::from((at.max(0) as u64).saturating_sub(RESUME_OVERLAP_SECS)))
    }

    /// (Re)opens the long-lived subscriptions for what we belong to.
    pub async fn resubscribe(&self) -> Result<()> {
        let me = self.keys.public_key();
        let me_hex = vec![me.to_hex()];
        let dm_newest = self.store.newest_tagged(&[Kind::GiftWrap.as_u16(), kinds::DM_LEGACY], 'p', &me_hex)?;
        self.pool.subscribe_keyed("dms", dm::filters(me, self.resume_from(dm_newest))).await?;

        let gids = self.servers()?;
        let mut groups = HashMap::new();
        for gid in &gids {
            if let Some(state) = self.server(gid)? {
                for c in &state.structure.channels {
                    if let Some(g) = &c.group_id {
                        groups.insert(g.clone(), (gid.clone(), c.id.clone()));
                    }
                }
            }
        }
        if gids.is_empty() {
            self.pool.unsubscribe_keyed("servers").await;
        } else {
            let exact: Vec<String> = gids
                .iter()
                .flat_map(|g| [dtag::metadata(g), dtag::structure(g), dtag::roles(g), dtag::emojis(g), dtag::stickers(g)])
                .collect();
            let state_kinds = [kinds::SERVER_METADATA, kinds::SERVER_STRUCTURE, kinds::SERVER_ROLES, kinds::SERVER_EMOJI, kinds::SERVER_STICKERS];
            self.pool
                .subscribe_keyed("servers", vec![
                    Filter::new().kinds(state_kinds.map(Kind::Custom)).identifiers(exact),
                    Filter::new()
                        .kinds([kinds::SERVER_MEMBER, kinds::SERVER_BAN, kinds::SERVER_INVITE].map(Kind::Custom))
                        .since(self.started_at),
                ])
                .await?;
        }
        if groups.is_empty() {
            self.pool.unsubscribe_keyed("channels").await;
        } else {
            let group_ids: Vec<String> = groups.keys().cloned().collect();
            let mut filter = Filter::new()
                .kinds(CHANNEL_KINDS.map(Kind::Custom))
                .custom_tags(SingleLetterTag::from_char('h').expect("h"), group_ids.clone());
            // Resume from what's cached; new servers get `backfill` instead.
            // The start point is pinned per session so the filter stays equal
            // across refreshes and re-subscribing stays a no-op.
            let newest = self.store.newest_tagged(&CHANNEL_KINDS, 'h', &group_ids)?;
            let since = self.resume_from(newest).map_or(self.started_at, |t| t.min(self.started_at));
            filter = filter.since(since);
            self.pool.subscribe_keyed("channels", vec![filter]).await?;
        }
        *self.groups.lock().unwrap_or_else(|e| e.into_inner()) = groups;
        Ok(())
    }

    fn rebuild_channel_keys(&self) -> Result<()> {
        let wraps = self.store.events_by_tag(Kind::GiftWrap, 'p', &self.keys.public_key().to_hex(), usize::MAX >> 1)?;
        for gid in self.servers()? {
            let Some(state) = self.server(&gid)? else { continue };
            let mut ck = ChannelKeys::default();
            for w in &wraps {
                ck.accept(&self.keys, &state, w);
            }
            self.channel_keys.lock().unwrap_or_else(|e| e.into_inner()).insert(gid, ck);
        }
        Ok(())
    }

    fn spawn_listener(self: &Arc<Self>) {
        let me = Arc::downgrade(self);
        let mut notifications = self.pool.notifications();
        tokio::spawn(async move {
            while let Some(n) = notifications.next().await {
                let ClientNotification::Event { event, .. } = n else { continue };
                let Some(session) = me.upgrade() else { break };
                if let Err(e) = session.handle(&event).await {
                    tracing::warn!("handling {}: {e}", event.id);
                }
            }
        });
    }

    async fn handle(&self, event: &Event) -> Result<()> {
        let kind = event.kind.as_u16();
        match kind {
            _ if event.kind == Kind::GiftWrap || event.kind == Kind::PrivateDirectMessage => {
                if let Ok(msg) = dm::open(&self.keys, event) {
                    self.store.put_event(event)?;
                    if !self.blocked()?.contains(&msg.sender) {
                        let _ = self.updates.send(Update::Dm(msg));
                    }
                } else if event.kind == Kind::GiftWrap {
                    self.try_key_share(event)?;
                }
            }
            kinds::SERVER_METADATA..=kinds::SERVER_INVITE => {
                let Some(gid) = wire::server_gid(event) else { return Ok(()) };
                if !self.servers()?.contains(&gid) {
                    return Ok(());
                }
                let was_member = kind == kinds::SERVER_MEMBER
                    && wire::target(event).is_some_and(|p| {
                        self.server(&gid).ok().flatten().is_some_and(|s| s.is_member(&p))
                    });
                self.store.put_event(event)?;
                if kind == kinds::SERVER_MEMBER && !was_member {
                    if let Some(p) = wire::target(event) {
                        if self.server(&gid)?.is_some_and(|s| s.is_member(&p)) {
                            self.share_keys_with(&gid, p).await?;
                        }
                    }
                }
                if kind == kinds::SERVER_METADATA && self.server(&gid)?.is_some_and(|s| s.metadata.deleted) {
                    // The owner deleted it: drop it here too.
                    self.store.set_server_membership(&gid, false)?;
                    self.push_config();
                    self.refresh.notify_one();
                }
                if kind == kinds::SERVER_STRUCTURE || kind == kinds::SERVER_ROLES || kind == kinds::SERVER_MEMBER {
                    // New channels or changed access: refresh routing and keys,
                    // batched so a burst of member events is one refresh.
                    self.refresh.notify_one();
                }
                let _ = self.updates.send(Update::Server(gid));
            }
            _ if CHANNEL_KINDS.contains(&kind) => {
                let group = event.tags.iter().find_map(|t| {
                    let s = t.as_slice();
                    (s.first().map(String::as_str) == Some("h")).then(|| s.get(1).cloned()).flatten()
                });
                let route = group.and_then(|g| self.groups.lock().unwrap_or_else(|e| e.into_inner()).get(&g).cloned());
                if let Some((gid, channel_id)) = route {
                    self.store.put_event(event)?;
                    let _ = self.updates.send(Update::Channel { gid, channel_id });
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn try_key_share(&self, wrap: &Event) -> Result<()> {
        for gid in self.servers()? {
            let Some(state) = self.server(&gid)? else { continue };
            let mut all = self.channel_keys.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(channel_id) = all.entry(gid.clone()).or_default().accept(&self.keys, &state, wrap) {
                drop(all);
                self.store.put_event(wrap)?;
                let _ = self.updates.send(Update::Channel { gid, channel_id });
                return Ok(());
            }
        }
        Ok(())
    }
}
