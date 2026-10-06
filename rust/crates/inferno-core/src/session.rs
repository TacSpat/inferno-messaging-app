//! A signed-in client: relays, cache, sync and live subscriptions tied
//! together. The UI holds one `Session`, reads resolved state from it, and
//! listens on [`Session::updates`] to know what to redraw.
//!
//! Every incoming event goes into the cache first; state is always resolved
//! from the cache, so a restart shows the same thing a live session did.

use std::collections::{HashMap, HashSet};
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
use crate::social::{self, DmMessage, Friendship, Payload, Response, Rumor};


/// Authors per profile filter: relays cap filter sizes, and a server can
/// have thousands of members.
const PEOPLE_PER_FILTER: usize = 500;

/// A row of the DM sidebar.
#[derive(Debug, Clone, PartialEq)]
pub struct Conversation {
    pub with: PublicKey,
    pub last_at: i64,
    pub preview: String,
    pub unread: usize,
    /// From someone who isn't a friend and whom we haven't answered:
    /// Rails' message request.
    pub request: bool,
}

/// Per-person DM choices that follow the user across devices.
#[derive(Debug, Default)]
struct DmState {
    accepted: HashMap<PublicKey, i64>,
    ignored: HashMap<PublicKey, i64>,
    closed: HashMap<PublicKey, i64>,
}

#[derive(serde::Serialize, serde::Deserialize, Default)]
struct DmStateWire {
    #[serde(default)]
    accepted: HashMap<String, i64>,
    #[serde(default)]
    ignored: HashMap<String, i64>,
    #[serde(default)]
    closed: HashMap<String, i64>,
}

impl From<DmStateWire> for DmState {
    fn from(w: DmStateWire) -> Self {
        let conv = |m: HashMap<String, i64>| m.into_iter().filter_map(|(k, v)| Some((PublicKey::from_hex(&k).ok()?, v))).collect();
        DmState { accepted: conv(w.accepted), ignored: conv(w.ignored), closed: conv(w.closed) }
    }
}

impl From<&DmState> for DmStateWire {
    fn from(s: &DmState) -> Self {
        let conv = |m: &HashMap<PublicKey, i64>| m.iter().map(|(k, v)| (k.to_hex(), *v)).collect();
        DmStateWire { accepted: conv(&s.accepted), ignored: conv(&s.ignored), closed: conv(&s.closed) }
    }
}

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

const CHANNEL_KINDS: [u16; 4] = [kinds::CHANNEL_MESSAGE, kinds::CHANNEL_DELETE, kinds::PIN, kinds::REACTION];
const TIMELINE_LIMIT: usize = 5_000;

#[derive(Debug, Clone)]
pub enum Update {
    /// Server state changed (metadata, structure, roles, members, ...).
    Server(String),
    /// Something in this channel's timeline changed.
    Channel { gid: String, channel_id: String },
    Dm(IncomingDm),
    /// Friends, conversations or blocks changed.
    Social,
    /// A profile we were waiting for arrived.
    Profile(PublicKey),
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
        // Our own profile and block list, so the UI shows what other devices
        // last set.
        match pool
            .fetch(vec![
                Filter::new().kind(Kind::Metadata).author(keys.public_key()),
                Filter::new().kind(Kind::MuteList).author(keys.public_key()),
            ])
            .await
        {
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
        session.open_stored_dms()?;
        session.resubscribe().await?;
        session.spawn_listener();
        session.catch_up_people();
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

    // ─── DMs and friends ────────────────────────────────────────────────

    fn counterparty(&self, msg: &IncomingDm) -> PublicKey {
        let me = self.keys.public_key();
        if msg.sender == me {
            msg.recipient.unwrap_or(me)
        } else {
            msg.sender
        }
    }

    /// Caches a decrypted DM; true if it's new.
    fn keep_dm(&self, wrap: &EventId, msg: &IncomingDm) -> Result<bool> {
        self.store.mark_dm_opened(wrap)?;
        Ok(self.store.put_rumor(&Rumor {
            id: msg.id,
            sender: msg.sender,
            counterparty: self.counterparty(msg),
            created_at: msg.created_at.as_secs() as i64,
            body: msg.body.clone(),
        })?)
    }

    /// Opens any cached wraps not opened yet (e.g. from before this cache
    /// existed). Each wrap is decrypted once.
    fn open_stored_dms(&self) -> Result<()> {
        let me = self.keys.public_key().to_hex();
        let mut wraps = self.store.events_by_tag(Kind::GiftWrap, 'p', &me, usize::MAX >> 1)?;
        wraps.extend(self.store.events_by_tag(Kind::Custom(kinds::DM_LEGACY), 'p', &me, usize::MAX >> 1)?);
        for w in wraps {
            if self.store.dm_opened(&w.id)? {
                continue;
            }
            match dm::open(&self.keys, &w) {
                Ok(msg) => {
                    self.keep_dm(&w.id, &msg)?;
                }
                Err(_) => self.store.mark_dm_opened(&w.id)?,
            }
        }
        if let Some(mutes) = self.store.get_addressable(Kind::MuteList, &self.keys.public_key(), "")? {
            self.apply_mute_list(&mutes)?;
        }
        Ok(())
    }

    /// Sends one DM payload as NIP-17 and keeps it locally right away.
    pub async fn send_dm(&self, to: &PublicKey, payload: &Payload) -> Result<EventId> {
        // After everything already in this conversation: ties are ordered
        // by id, which would put an edit before its message half the time.
        let last = self.store.rumors_with(to)?.iter().map(|r| r.created_at).max();
        let at = crate::sync::publish_time(last.map(|t| Timestamp::from(t as u64)));
        let events = dm::build_at(&self.keys, *to, &payload.body(), vec![], at).map_err(|e| SessionError::Other(e.to_string()))?;
        let own = events.last().expect("at least one wrap");
        let msg = dm::open(&self.keys, own).map_err(|e| SessionError::Other(e.to_string()))?;
        for e in &events {
            self.store.put_event(e)?;
        }
        self.keep_dm(&own.id, &msg)?;
        let _ = self.updates.send(Update::Social);
        let mut accepted = false;
        for e in &events {
            accepted |= self.pool.publish(e).await?.any_accepted();
        }
        if !accepted {
            return Err(SessionError::NotPublished);
        }
        Ok(msg.id)
    }

    pub fn friendships(&self) -> Result<HashMap<PublicKey, Friendship>> {
        let ignored = self.dm_state()?.ignored;
        let blocked = self.blocked()?;
        let mut f = social::friendships(&self.keys.public_key(), &self.store.rumors()?, &ignored);
        f.retain(|pk, _| !blocked.contains(pk));
        Ok(f)
    }

    pub fn friendship(&self, pk: &PublicKey) -> Result<Friendship> {
        Ok(self.friendships()?.get(pk).copied().unwrap_or_default())
    }

    /// Add Friend; accepts instead if they already asked us.
    pub async fn add_friend(&self, pk: &PublicKey) -> Result<()> {
        let payload = match self.friendship(pk)? {
            Friendship::Incoming => Payload::FriendResponse(Response::Accepted),
            Friendship::Accepted | Friendship::Outgoing => return Ok(()),
            Friendship::None => Payload::FriendRequest,
        };
        self.send_dm(pk, &payload).await?;
        self.want_profiles(&[*pk]).await;
        Ok(())
    }

    pub async fn answer_friend(&self, pk: &PublicKey, accept: bool) -> Result<()> {
        let r = if accept { Response::Accepted } else { Response::Declined };
        self.send_dm(pk, &Payload::FriendResponse(r)).await?;
        Ok(())
    }

    /// Remove Friend, or cancel an outgoing request.
    pub async fn remove_friend(&self, pk: &PublicKey) -> Result<()> {
        self.send_dm(pk, &Payload::FriendResponse(Response::Removed)).await?;
        Ok(())
    }

    /// Rails' Ignore: hides the request here, tells them nothing.
    pub fn ignore_friend(&self, pk: &PublicKey) -> Result<()> {
        self.edit_dm_state(|s| {
            s.ignored.insert(*pk, now_secs());
        })
    }

    /// One conversation's messages, oldest first.
    pub fn dm_messages(&self, with: &PublicKey) -> Result<Vec<DmMessage>> {
        Ok(social::conversation(&self.store.rumors_with(with)?))
    }

    /// The DM sidebar: newest first. Blocked people and closed conversations
    /// (with nothing newer) are left out.
    pub fn conversations(&self) -> Result<Vec<Conversation>> {
        let me = self.keys.public_key();
        let state = self.dm_state()?;
        let blocked = self.blocked()?;
        let friends = self.friendships()?;
        let mut by: HashMap<PublicKey, Vec<Rumor>> = HashMap::new();
        for r in self.store.rumors()? {
            by.entry(r.counterparty).or_default().push(r);
        }
        let mut out = Vec::new();
        for (with, rumors) in by {
            if blocked.contains(&with) {
                continue;
            }
            let messages = social::conversation(&rumors);
            let Some(last) = messages.last() else { continue };
            if state.closed.get(&with).is_some_and(|at| *at >= last.created_at) {
                continue;
            }
            let read = self.store.last_read(&format!("dm:{}", with.to_hex()))?.unwrap_or(0);
            let unread = messages.iter().filter(|m| m.author != me && m.created_at > read).count();
            let request = with != me
                && friends.get(&with) != Some(&Friendship::Accepted)
                && !state.accepted.contains_key(&with)
                && !messages.iter().any(|m| m.author == me);
            out.push(Conversation {
                with,
                last_at: last.created_at,
                preview: last.content.chars().take(80).collect(),
                unread,
                request,
            });
        }
        out.sort_by_key(|c| std::cmp::Reverse(c.last_at));
        Ok(out)
    }

    /// Accepts a message request (Rails: shows the messages, unblurs links).
    pub fn accept_dm(&self, with: &PublicKey) -> Result<()> {
        self.edit_dm_state(|s| {
            s.accepted.insert(*with, now_secs());
        })
    }

    /// Rails' Close Conversation (and Decline on a request): hidden until a
    /// new message arrives.
    pub fn close_dm(&self, with: &PublicKey) -> Result<()> {
        let at = self.store.rumors_with(with)?.iter().map(|r| r.created_at).max().unwrap_or_else(now_secs);
        self.edit_dm_state(|s| {
            s.closed.insert(*with, at);
        })
    }

    pub fn mark_dm_read(&self, with: &PublicKey) -> Result<()> {
        let at = self.store.rumors_with(with)?.iter().map(|r| r.created_at).max().unwrap_or_else(now_secs);
        self.store.mark_read(&format!("dm:{}", with.to_hex()), at)?;
        self.push_config();
        let _ = self.updates.send(Update::Social);
        Ok(())
    }

    fn dm_state(&self) -> Result<DmState> {
        Ok(self
            .store
            .synced_setting("dm_state")?
            .and_then(|v| serde_json::from_value::<DmStateWire>(v).ok())
            .map(DmState::from)
            .unwrap_or_default())
    }

    fn edit_dm_state(&self, f: impl FnOnce(&mut DmState)) -> Result<()> {
        let mut state = self.dm_state()?;
        f(&mut state);
        let wire = DmStateWire::from(&state);
        self.store.set_synced_setting("dm_state", serde_json::to_value(wire).map_err(|e| SessionError::Other(e.to_string()))?)?;
        self.push_config();
        let _ = self.updates.send(Update::Social);
        Ok(())
    }

    pub fn blocked_list(&self) -> Result<Vec<PublicKey>> {
        Ok(self.blocked()?.into_iter().collect())
    }

    /// Rails' Block User: they're dropped from friends and DMs, and the
    /// list syncs as a NIP-51 mute list with the entries encrypted to
    /// ourselves (Rails published them in the clear).
    pub async fn block(&self, pk: &PublicKey) -> Result<()> {
        if self.friendship(pk)? != Friendship::None {
            let _ = self.send_dm(pk, &Payload::FriendResponse(Response::Removed)).await;
        }
        self.store.block(&pk.to_hex())?;
        self.publish_mute_list().await
    }

    pub async fn unblock(&self, pk: &PublicKey) -> Result<()> {
        self.store.unblock(&pk.to_hex())?;
        self.publish_mute_list().await
    }

    async fn publish_mute_list(&self) -> Result<()> {
        let tags: Vec<Vec<String>> = self.store.blocked_pubkeys()?.into_iter().map(|h| vec!["p".to_owned(), h]).collect();
        let plain = serde_json::to_string(&tags).map_err(|e| SessionError::Other(e.to_string()))?;
        let content = nostr::nips::nip44::encrypt(self.keys.secret_key(), &self.keys.public_key(), plain, nostr::nips::nip44::Version::V2)
            .map_err(|e| SessionError::Other(e.to_string()))?;
        let event = EventBuilder::new(Kind::MuteList, content).finalize(&self.keys).map_err(|e| SessionError::Other(e.to_string()))?;
        let _ = self.updates.send(Update::Social);
        self.publish(&event).await?;
        Ok(())
    }

    /// Replaces our blocks with a mute list from another device. Public `p`
    /// tags (other clients) count too.
    fn apply_mute_list(&self, event: &Event) -> Result<()> {
        let mut pks: Vec<String> = event.tags.public_keys().map(|p| p.to_hex()).collect();
        if let Ok(plain) = nostr::nips::nip44::decrypt(self.keys.secret_key(), &self.keys.public_key(), &event.content) {
            if let Ok(tags) = serde_json::from_str::<Vec<Vec<String>>>(&plain) {
                pks.extend(tags.into_iter().filter(|t| t.first().map(String::as_str) == Some("p")).filter_map(|t| t.get(1).cloned()));
            }
        }
        for h in self.store.blocked_pubkeys()? {
            if !pks.contains(&h) {
                self.store.unblock(&h)?;
            }
        }
        for h in &pks {
            self.store.block(h)?;
        }
        Ok(())
    }

    /// Someone's kind 0, if we have it.
    pub fn profile_of(&self, pk: &PublicKey) -> Result<Option<crate::server::wire::MemberProfile>> {
        Ok(self.store.get_addressable(Kind::Metadata, pk, "")?.map(|e| profile::member_profile(&profile::content(&e))))
    }

    /// One profile per person, the same in every server, DM and list: their
    /// kind 0, with any field it lacks taken from the profile they carry in a
    /// server we share (Rails puts colours there, not in kind 0). Rails and
    /// Flutter kept a copy per server and per contact, which drifted apart
    /// and grew with every server. Nicknames and roles stay per server.
    pub fn profile(&self, pk: &PublicKey) -> Result<crate::server::wire::MemberProfile> {
        let states: Vec<ServerState> = self.servers()?.iter().filter_map(|g| self.server(g).ok().flatten()).collect();
        Ok(profile::merge(self.profile_of(pk)?, states.iter().filter_map(|s| s.members.get(pk)).map(|m| &m.profile)))
    }

    /// Everyone whose profile we show: members of our servers, DM peers,
    /// friends and requests, and ourselves. Each once.
    pub fn known_people(&self) -> Result<Vec<PublicKey>> {
        let mut set: HashSet<PublicKey> = HashSet::new();
        set.insert(self.keys.public_key());
        for gid in self.servers()? {
            if let Some(state) = self.server(&gid)? {
                set.extend(state.members.keys().copied());
            }
        }
        for r in self.store.rumors()? {
            set.insert(r.counterparty);
        }
        let mut v: Vec<PublicKey> = set.into_iter().collect();
        v.sort();
        Ok(v)
    }

    /// At startup: profiles that changed while we were away (since the newest
    /// we hold), and those we never had. In the background, a few REQs.
    fn catch_up_people(&self) {
        let Ok(people) = self.known_people() else { return };
        let hexes: Vec<String> = people.iter().map(|p| p.to_hex()).collect();
        let Ok((have, newest)) = self.store.authors_with(Kind::Metadata.as_u16(), &hexes) else { return };
        let (known, unknown): (Vec<PublicKey>, Vec<PublicKey>) = people.into_iter().partition(|p| have.contains(&p.to_hex()));
        let since = self.resume_from(newest);
        let mut filters: Vec<Filter> = Vec::new();
        for c in known.chunks(PEOPLE_PER_FILTER) {
            let f = Filter::new().kind(Kind::Metadata).authors(c.iter().copied());
            filters.push(match since {
                Some(t) => f.since(t),
                None => f,
            });
        }
        for c in unknown.chunks(PEOPLE_PER_FILTER) {
            filters.push(Filter::new().kind(Kind::Metadata).authors(c.iter().copied()));
        }
        if filters.is_empty() {
            return;
        }
        let (pool, store, updates) = (self.pool.clone(), self.store.clone(), self.updates.clone());
        tokio::spawn(async move {
            match pool.fetch(filters).await {
                Ok(events) => {
                    for e in &events {
                        if matches!(store.put_event(e), Ok(crate::store::PutOutcome::Inserted)) {
                            let _ = updates.send(Update::Profile(e.pubkey));
                        }
                    }
                }
                Err(e) => tracing::warn!("profile catch-up failed: {e}"),
            }
        });
    }

    /// Fetches profiles we don't have yet, in the background. A full fetch
    /// per person would hammer relays, so missing ones go in one filter.
    pub async fn want_profiles(&self, pks: &[PublicKey]) {
        let missing: Vec<PublicKey> = pks
            .iter()
            .filter(|p| self.store.get_addressable(Kind::Metadata, p, "").ok().flatten().is_none())
            .copied()
            .collect();
        if missing.is_empty() {
            return;
        }
        let (pool, store, updates) = (self.pool.clone(), self.store.clone(), self.updates.clone());
        tokio::spawn(async move {
            if let Ok(events) = pool.fetch(vec![Filter::new().kind(Kind::Metadata).authors(missing)]).await {
                for e in &events {
                    if store.put_event(e).is_ok() {
                        let _ = updates.send(Update::Profile(e.pubkey));
                    }
                }
            }
        });
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
            }
            if let Ok(p) = self.profile(pk) {
                v.push(p.display_name);
                v.push(p.name);
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
        // Our block list (NIP-51 mute list, kept private).
        self.pool.subscribe_keyed("mutes", vec![Filter::new().kind(Kind::MuteList).author(me)]).await?;
        // Everyone we know, once: profile changes from here on.
        let people = self.known_people()?;
        if !people.is_empty() {
            let filters = people
                .chunks(PEOPLE_PER_FILTER)
                .map(|c| Filter::new().kind(Kind::Metadata).authors(c.iter().copied()).since(self.started_at))
                .collect();
            self.pool.subscribe_keyed("people", filters).await?;
        }

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
                    let new = self.keep_dm(&event.id, &msg)?;
                    if new && !self.blocked()?.contains(&msg.sender) {
                        let counterparty = self.counterparty(&msg);
                        if self.store.rumors_with(&counterparty)?.len() == 1 {
                            // Someone new: follow their profile from now on.
                            self.refresh.notify_one();
                        }
                        self.want_profiles(&[counterparty]).await;
                        let _ = self.updates.send(Update::Dm(msg));
                        let _ = self.updates.send(Update::Social);
                    }
                } else if event.kind == Kind::GiftWrap {
                    self.try_key_share(event)?;
                }
            }
            _ if event.kind == Kind::MuteList && event.pubkey == self.keys.public_key() => {
                if matches!(self.store.put_event(event)?, crate::store::PutOutcome::Inserted) {
                    self.apply_mute_list(event)?;
                    let _ = self.updates.send(Update::Social);
                }
            }
            _ if event.kind == Kind::Metadata => {
                if matches!(self.store.put_event(event)?, crate::store::PutOutcome::Inserted) {
                    let _ = self.updates.send(Update::Profile(event.pubkey));
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
