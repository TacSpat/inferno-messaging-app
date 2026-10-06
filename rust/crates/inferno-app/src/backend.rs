//! The session thread. The core `Session` is async and does network I/O, so
//! it lives on its own tokio runtime; the UI thread never waits on it. The UI
//! sends [`Command`]s; the backend answers with [`Update`]s posted through
//! `Cx::post_action`, already shaped for drawing (names resolved, colors
//! picked, grouping decided), so the UI only copies them into its lists.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use inferno_core::channel::send::Outgoing;
use inferno_core::keys::Identity;
use inferno_core::nostr_sdk::prelude::*;
use inferno_core::server::ServerState;
use inferno_core::session::{Session, StartOptions, Update as SessionUpdate};
use inferno_core::store::{RelaySource, Store};
use inferno_core::vault::{OsKeyring, Vault};
use makepad_widgets::Cx;
use tokio::sync::mpsc;

// ─── What the UI draws ───────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub struct ServerItem {
    pub gid: String,
    pub name: String,
    pub initials: String,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SidebarRow {
    Category { id: String, name: String },
    Channel { id: String, name: String, voice: bool, encrypted: bool, category: Option<String> },
}

/// What we may do in the selected server (drives which controls show).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ServerPerms {
    pub manage_channels: bool,
    pub manage_server: bool,
    pub manage_roles: bool,
    pub manage_messages: bool,
    pub kick_members: bool,
    pub ban_members: bool,
    pub create_invite: bool,
    pub owner: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RoleItem {
    pub id: String,
    pub name: String,
}

/// A role as the roles page edits it.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct RoleForm {
    pub id: String,
    pub name: String,
    pub color: String,
    pub position: i64,
    pub hoist: bool,
    pub mentionable: bool,
    /// Granted permission keys (Rails' names).
    pub perms: Vec<String>,
    pub everyone: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BanItem {
    pub pubkey: String,
    pub name: String,
    pub reason: String,
}

/// Everything the server settings pages show.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ServerSettings {
    pub name: String,
    pub about: String,
    pub discoverable: bool,
    pub age_restricted: bool,
    pub welcome_enabled: bool,
    pub welcome_message: String,
    /// Highest position first, as Rails lists them.
    pub roles: Vec<RoleForm>,
    pub bans: Vec<BanItem>,
}

/// A channel as the edit dialog needs it.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ChannelForm {
    pub id: Option<String>,
    pub name: String,
    pub topic: String,
    pub voice: bool,
    pub category: Option<String>,
    pub encrypted: bool,
    pub allowed_roles: Vec<String>,
    pub post_only: bool,
    pub nsfw: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MemberRow {
    Header { text: String, color: u32 },
    Member {
        name: String,
        initial: String,
        color: u32,
        avatar: u32,
        pubkey: String,
        roles: Vec<String>,
        owner: bool,
        me: bool,
    },
}

#[derive(Debug, Clone, PartialEq)]
pub struct MessageRow {
    /// Event id (hex); empty for demo rows.
    pub id: String,
    /// Sent by us: offers Edit.
    pub own: bool,
    /// The parent's event id, for jump-to-reply.
    pub reply_to: Option<String>,
    pub author: String,
    pub initial: String,
    pub color: u32,
    pub avatar: u32,
    pub at: i64,
    /// `None` = encrypted and we don't have the key.
    pub body: Option<String>,
    pub reply: Option<String>,
    pub edited: bool,
    pub pinned: bool,
    /// Same author, under 5 minutes, not a reply: drawn without the header.
    pub grouped: bool,
    pub system: bool,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ProfileForm {
    pub username: String,
    pub display_name: String,
    pub about: String,
    pub status: String,
    pub status_emoji: String,
    pub color: String,
    pub color_2: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct RelayItem {
    pub url: String,
    pub read: bool,
    pub write: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SearchRow {
    pub channel_id: String,
    pub channel_name: String,
    pub id: String,
    pub author: String,
    pub color: u32,
    pub at: i64,
    pub body: String,
}

#[derive(Debug, Clone)]
pub enum Update {
    /// The theme this account uses (synced across devices).
    Theme(String),
    SearchResults { query: String, rows: Vec<SearchRow> },
    ServerSettings(ServerSettings),
    Profile(ProfileForm),
    Relays(Vec<RelayItem>),
    /// The ncryptsec of a new backup (also copied to the clipboard).
    BackedUp(String),
    Ready { name: String, npub: String, backed_up: bool },
    Servers(Vec<ServerItem>),
    Server {
        gid: String,
        name: String,
        sidebar: Vec<SidebarRow>,
        members: Vec<MemberRow>,
        perms: ServerPerms,
        /// Roles, for encrypted-channel access.
        roles: Vec<RoleItem>,
        /// Categories by position (id, real-case name), for pickers.
        categories: Vec<RoleItem>,
        /// Every channel's editable fields, by id.
        channels: Vec<ChannelForm>,
    },
    Channel { gid: String, channel_id: String, name: String, topic: String, encrypted: bool },
    Timeline { gid: String, channel_id: String, rows: Vec<MessageRow>, can_pin: bool },
    Invite(String),
    Error(String),
    /// Nothing selected: no servers yet.
    Empty,
}

#[derive(Debug)]
pub enum Command {
    SelectServer(String),
    SelectChannel(String),
    Send { text: String, reply_to: Option<String> },
    Edit { id: String, text: String },
    Pin { id: String, pinned: bool },
    CreateServer(String),
    Join(String),
    CreateInvite,
    SaveProfile(ProfileForm),
    Backup(String),
    AddRelay(String),
    RemoveRelay(String),
    SaveChannel(ChannelForm),
    DeleteChannel(String),
    CreateCategory(String),
    RenameCategory { id: String, name: String },
    DeleteCategory(String),
    /// Move a channel to `index` within `category` (None = top level).
    MoveChannel { id: String, category: Option<String>, index: usize },
    LeaveServer,
    MarkRead(String),
    DeleteMessage(String),
    Search(String),
    SetTheme(String),
    SaveOverview(ServerSettings),
    SaveRoles(Vec<RoleForm>),
    Unban(String),
    DeleteServer,
    SetMemberRoles { pubkey: String, roles: Vec<String> },
    Kick(String),
    Timeout { pubkey: String, secs: i64 },
    Ban { pubkey: String, reason: String },
}

// ─── Startup ─────────────────────────────────────────────────────────────

fn data_dir() -> PathBuf {
    let base = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/share")))
        .unwrap_or_else(|| PathBuf::from("."));
    base.join("inferno")
}

/// `INFERNO_PROFILE=name` runs a separate identity and cache (two instances
/// side by side); `INFERNO_RELAYS=wss://a,ws://b` replaces the relay list and
/// skips the public defaults (local testing with inferno-devrelay).
fn profile() -> String {
    std::env::var("INFERNO_PROFILE").unwrap_or_else(|_| "default".into())
}

fn open_vault() -> Result<Vault<OsKeyring>, String> {
    let service = match profile().as_str() {
        "default" => "inferno".to_owned(),
        p => format!("inferno-{p}"),
    };
    Ok(Vault::new(OsKeyring::with_service(&service).map_err(|e| e.to_string())?))
}

fn load_identity(vault: &Vault<OsKeyring>) -> Result<(Identity, bool), String> {
    if let Some(id) = vault.active().map_err(|e| e.to_string())? {
        let backed_up = vault.has_backup(&id.pubkey_hex()).map_err(|e| e.to_string())?;
        return Ok((id, backed_up));
    }
    // First run: no onboarding screen yet, so create a key now and keep it;
    // the backup step (Settings › My Account) finishes the sign-up.
    let id = Identity::generate();
    vault.sign_up_pending_backup(&id, "").map_err(|e| e.to_string())?;
    Ok((id, false))
}

pub fn spawn() -> mpsc::UnboundedSender<Command> {
    let (tx, rx) = mpsc::unbounded_channel();
    std::thread::Builder::new()
        .name("inferno-session".into())
        .spawn(move || {
            let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("tokio runtime");
            rt.block_on(async move {
                if let Err(e) = run(rx).await {
                    Cx::post_action(Update::Error(e));
                }
            });
        })
        .expect("spawn session thread");
    tx
}

async fn run(mut commands: mpsc::UnboundedReceiver<Command>) -> Result<(), String> {
    let vault = open_vault()?;
    let (identity, backed_up) = load_identity(&vault)?;
    let keys = identity.keys().clone();
    let dir = data_dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let db = dir.join(format!("{}-{}.sqlite3", profile(), &identity.pubkey_hex()[..16]));
    let store = Store::open(&db).map_err(|e| e.to_string())?;

    let custom_relays: Vec<String> = std::env::var("INFERNO_RELAYS")
        .map(|v| v.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect())
        .unwrap_or_default();
    for r in &custom_relays {
        store.add_relay(r, RelaySource::User).map_err(|e| e.to_string())?;
    }
    let options = StartOptions { seed_default_relays: custom_relays.is_empty() };
    let session = Session::start_with(keys, store, options).await.map_err(|e| e.to_string())?;

    let mut ui = Backend { session: session.clone(), server: None, channel: None, vault, npub: identity.npub(), backed_up };
    if let Ok(Some(serde_json::Value::String(theme))) = session.synced_setting("theme") {
        Cx::post_action(Update::Theme(theme));
    }
    ui.publish_me();
    ui.publish_relays();
    ui.publish_servers();

    let mut updates = session.updates();
    loop {
        tokio::select! {
            cmd = commands.recv() => {
                let Some(cmd) = cmd else { break };
                if let Err(e) = ui.command(cmd).await {
                    Cx::post_action(Update::Error(e));
                }
            }
            update = updates.recv() => match update {
                Ok(u) => ui.session_update(u),
                // Fell behind a burst: just redraw everything once.
                Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => ui.refresh_all(),
                Err(_) => break,
            }
        }
    }
    Ok(())
}

// ─── The loop's state ────────────────────────────────────────────────────

struct Backend {
    session: Arc<Session>,
    server: Option<String>,
    channel: Option<String>,
    vault: Vault<OsKeyring>,
    npub: String,
    backed_up: bool,
}

fn initials(name: &str) -> String {
    let s: String = name.split_whitespace().filter_map(|w| w.chars().next()).take(2).collect();
    if s.is_empty() { "?".into() } else { s.to_uppercase() }
}

/// First character of the name, uppercased, for avatar placeholders.
/// Char-based: names may start with emoji or other multi-byte text.
fn first_initial(name: &str) -> String {
    name.chars().next().map(|c| c.to_uppercase().collect()).unwrap_or_else(|| "?".into())
}

fn member_row(state: &ServerState, pk: &PublicKey, me: &PublicKey) -> MemberRow {
    let d = display(state, pk);
    MemberRow::Member {
        initial: first_initial(&d.name),
        name: d.name,
        color: d.color,
        avatar: d.avatar,
        pubkey: pk.to_hex(),
        roles: state.members.get(pk).map(|m| m.roles.clone()).unwrap_or_default(),
        owner: state.is_owner(pk),
        me: pk == me,
    }
}

fn hex_color(s: &str) -> Option<u32> {
    u32::from_str_radix(s.trim_start_matches('#'), 16).ok().filter(|_| s.trim_start_matches('#').len() == 6)
}

const DEFAULT_ROLE: u32 = 0xcccbca; // gray-200, Rails' color for no role
const DEFAULT_AVATAR: u32 = 0x1e1c1b;

struct Display {
    name: String,
    color: u32,
    avatar: u32,
}

/// How a member shows up: nickname, display name, profile name, or a pubkey
/// prefix; colored by their highest colored role.
fn display(state: &ServerState, pk: &PublicKey) -> Display {
    let m = state.members.get(pk);
    let name = m
        .and_then(|m| m.nickname.clone())
        .or_else(|| m.map(|m| m.profile.display_name.clone()).filter(|s| !s.is_empty()))
        .or_else(|| m.map(|m| m.profile.name.clone()).filter(|s| !s.is_empty()))
        .unwrap_or_else(|| pk.to_hex()[..8].to_owned());
    let color = m
        .and_then(|m| {
            state
                .roles
                .iter()
                .filter(|r| m.roles.contains(&r.id) && !r.is_everyone() && r.color != "#99aab5")
                .max_by_key(|r| r.position)
                .and_then(|r| hex_color(&r.color))
        })
        .unwrap_or(DEFAULT_ROLE);
    let avatar = m.and_then(|m| m.profile.color.as_deref()).and_then(hex_color).unwrap_or(DEFAULT_AVATAR);
    Display { name, color, avatar }
}

impl Backend {
    fn selected(&self) -> Result<(String, String), String> {
        match (self.server.clone(), self.channel.clone()) {
            (Some(g), Some(c)) => Ok((g, c)),
            _ => Err("Pick a channel first.".into()),
        }
    }

    async fn command(&mut self, cmd: Command) -> Result<(), String> {
        match cmd {
            Command::SelectServer(gid) => {
                self.server = Some(gid);
                self.channel = None;
                self.publish_server();
            }
            Command::SelectChannel(id) => {
                self.channel = Some(id);
                self.publish_channel();
            }
            Command::Send { text, reply_to } => {
                let (gid, ch) = self.selected()?;
                let reply_to = reply_to.and_then(|id| EventId::from_hex(&id).ok());
                self.session
                    .send(&gid, &ch, &Outgoing { content: &text, reply_to, ..Default::default() })
                    .await
                    .map_err(|e| e.to_string())?;
                self.publish_timeline();
            }
            Command::Edit { id, text } => {
                let (gid, ch) = self.selected()?;
                let id = EventId::from_hex(&id).map_err(|e| e.to_string())?;
                self.session.edit(&gid, &ch, id, &text).await.map_err(|e| e.to_string())?;
                self.publish_timeline();
            }
            Command::Pin { id, pinned } => {
                let (gid, ch) = self.selected()?;
                let id = EventId::from_hex(&id).map_err(|e| e.to_string())?;
                self.session.pin(&gid, &ch, id, pinned).await.map_err(|e| e.to_string())?;
                self.publish_timeline();
            }
            Command::CreateServer(name) => {
                let gid = self.session.create_server(name.trim()).await.map_err(|e| e.to_string())?;
                self.server = Some(gid);
                self.channel = None;
                self.publish_servers();
                self.publish_server();
            }
            Command::Join(link) => {
                let gid = self.session.join(link.trim()).await.map_err(|e| e.to_string())?;
                self.server = Some(gid);
                self.channel = None;
                self.publish_servers();
                self.publish_server();
            }
            Command::SaveProfile(form) => {
                use inferno_core::sync::profile::ProfileUpdate;
                // Empty fields clear; every field is sent, it's a whole form.
                let set = |v: &str| Some(Some(v.trim().to_owned()));
                self.session
                    .update_profile(&ProfileUpdate {
                        name: set(&form.username),
                        display_name: set(&form.display_name),
                        about: set(&form.about),
                        status: set(&form.status),
                        status_emoji: set(&form.status_emoji),
                        profile_color: set(&form.color),
                        profile_color_2: set(&form.color_2),
                        ..Default::default()
                    })
                    .await
                    .map_err(|e| e.to_string())?;
                self.publish_me();
                self.publish_server_keep_channel();
            }
            Command::Backup(password) => {
                if password.chars().count() < 8 {
                    return Err("Use at least 8 characters for the backup password.".into());
                }
                let backup = self.vault.add_backup(&password).map_err(|e| e.to_string())?;
                self.backed_up = true;
                self.publish_me();
                Cx::post_action(Update::BackedUp(backup));
            }
            Command::AddRelay(url) => {
                self.session.add_relay(url.trim()).await.map_err(|e| e.to_string())?;
                self.publish_relays();
            }
            Command::RemoveRelay(url) => {
                self.session.remove_relay(&url).await.map_err(|e| e.to_string())?;
                self.publish_relays();
            }
            Command::SaveChannel(form) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                if form.name.trim().is_empty() {
                    return Err("Give the channel a name.".into());
                }
                // Rails channel names: lowercase, spaces become dashes.
                let name = form.name.trim().to_lowercase().replace(' ', "-");
                match &form.id {
                    None => {
                        let spec = inferno_core::session::ChannelSpec {
                            name,
                            voice: form.voice,
                            category: form.category.clone(),
                            topic: form.topic.clone(),
                            encrypted: form.encrypted,
                            allowed_roles: form.allowed_roles.clone(),
                            post_only: form.post_only,
                            nsfw: form.nsfw,
                        };
                        let id = self.session.create_channel(&gid, &spec).await.map_err(|e| e.to_string())?;
                        if !form.voice {
                            self.channel = Some(id);
                        }
                    }
                    Some(id) => {
                        let f = form.clone();
                        self.session
                            .update_channel(&gid, id, move |c| {
                                c.name = name;
                                c.topic = f.topic;
                                c.post_only = f.post_only;
                                c.nsfw = f.nsfw;
                                if c.encrypted {
                                    let mut o = c.permission_overrides.clone();
                                    o.insert("allowed_role_ids".into(), serde_json::json!(f.allowed_roles));
                                    c.permission_overrides = o;
                                }
                            })
                            .await
                            .map_err(|e| e.to_string())?;
                    }
                }
                self.publish_server_keep_channel();
            }
            Command::DeleteChannel(id) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.delete_channel(&gid, &id).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::CreateCategory(name) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                if name.trim().is_empty() {
                    return Err("Give the category a name.".into());
                }
                self.session.create_category(&gid, &name).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::RenameCategory { id, name } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.rename_category(&gid, &id, &name).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::DeleteCategory(id) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.delete_category(&gid, &id).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::MoveChannel { id, category, index } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.move_channel(&gid, &id, category.as_deref(), index).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::SaveOverview(o) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                if o.name.trim().is_empty() {
                    return Err("The server needs a name.".into());
                }
                self.session
                    .update_metadata(&gid, move |m| {
                        m.name = o.name.trim().to_owned();
                        m.about = o.about;
                        m.discoverable = o.discoverable;
                        m.age_restricted = o.age_restricted;
                        m.welcome_enabled = o.welcome_enabled;
                        m.welcome_message = o.welcome_message;
                    })
                    .await
                    .map_err(|e| e.to_string())?;
                self.publish_servers();
                self.publish_server_keep_channel();
            }
            Command::SaveRoles(forms) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let roles = forms
                    .into_iter()
                    .map(|f| inferno_core::server::wire::Role {
                        id: f.id,
                        name: f.name.trim().to_owned(),
                        color: f.color,
                        position: f.position,
                        hoist: f.hoist,
                        mentionable: f.mentionable,
                        permissions: f.perms.into_iter().map(|k| (k, serde_json::Value::Bool(true))).collect(),
                        role_type: String::new(),
                    })
                    .collect();
                self.session.save_roles(&gid, roles).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::Unban(pubkey) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let pk = PublicKey::from_hex(&pubkey).map_err(|e| e.to_string())?;
                self.session.unban(&gid, &pk).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::DeleteServer => {
                let gid = self.server.take().ok_or("Pick a server first.")?;
                self.session.delete_server(&gid).await.map_err(|e| e.to_string())?;
                self.channel = None;
                self.publish_servers();
            }
            Command::SetTheme(name) => {
                self.session.set_synced_setting("theme", serde_json::json!(name)).map_err(|e| e.to_string())?;
            }
            Command::Search(text) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let query = inferno_core::search::Query::parse(&text);
                if query.is_empty() {
                    return Ok(());
                }
                let state = self.session.server(&gid).map_err(|e| e.to_string())?.ok_or("Unknown server")?;
                let rows = self
                    .session
                    .search(&gid, &query, 100)
                    .map_err(|e| e.to_string())?
                    .into_iter()
                    .map(|h| {
                        let d = display(&state, &h.message.author);
                        SearchRow {
                            channel_id: h.channel_id,
                            channel_name: h.channel_name,
                            id: h.message.id.to_hex(),
                            author: d.name,
                            color: d.color,
                            at: h.message.created_at,
                            body: h.message.content.unwrap_or_default(),
                        }
                    })
                    .collect();
                Cx::post_action(Update::SearchResults { query: text, rows });
            }
            Command::DeleteMessage(id) => {
                let (gid, ch) = self.selected()?;
                let id = EventId::from_hex(&id).map_err(|e| e.to_string())?;
                self.session.delete_message(&gid, &ch, id).await.map_err(|e| e.to_string())?;
                self.publish_timeline();
            }
            Command::SetMemberRoles { pubkey, roles } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let pk = PublicKey::from_hex(&pubkey).map_err(|e| e.to_string())?;
                self.session.set_member_roles(&gid, &pk, &roles).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::Kick(pubkey) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let pk = PublicKey::from_hex(&pubkey).map_err(|e| e.to_string())?;
                self.session.kick(&gid, &pk).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::Timeout { pubkey, secs } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let pk = PublicKey::from_hex(&pubkey).map_err(|e| e.to_string())?;
                let until = if secs > 0 { inferno_core::store::now_secs() + secs } else { 0 };
                self.session.timeout(&gid, &pk, until).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::Ban { pubkey, reason } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let pk = PublicKey::from_hex(&pubkey).map_err(|e| e.to_string())?;
                self.session.ban(&gid, &pk, &reason).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::MarkRead(id) => {
                self.session.store().mark_read(&id, inferno_core::store::now_secs()).map_err(|e| e.to_string())?;
            }
            Command::LeaveServer => {
                let gid = self.server.take().ok_or("Pick a server first.")?;
                self.session.leave(&gid).await.map_err(|e| e.to_string())?;
                self.channel = None;
                self.publish_servers();
            }
            Command::CreateInvite => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let link = self.session.create_invite(&gid).await.map_err(|e| e.to_string())?;
                Cx::post_action(Update::Invite(link));
            }
        }
        Ok(())
    }

    fn publish_me(&mut self) {
        let p = self.session.my_profile().unwrap_or_default();
        let s = |k: &str| p.get(k).and_then(|v| v.as_str()).unwrap_or_default().to_owned();
        let form = ProfileForm {
            username: s("name"),
            display_name: s("display_name"),
            about: s("about"),
            status: s("status"),
            status_emoji: s("status_emoji"),
            color: s("profile_color"),
            color_2: s("profile_color_2"),
        };
        let name = [form.display_name.clone(), form.username.clone()]
            .into_iter()
            .find(|n| !n.is_empty())
            .unwrap_or_else(|| self.npub[..12].to_owned());
        Cx::post_action(Update::Ready { name, npub: self.npub.clone(), backed_up: self.backed_up });
        Cx::post_action(Update::Profile(form));
    }

    fn publish_relays(&mut self) {
        let relays = self
            .session
            .relays()
            .unwrap_or_default()
            .into_iter()
            .map(|r| RelayItem { url: r.url, read: r.read, write: r.write })
            .collect();
        Cx::post_action(Update::Relays(relays));
    }

    fn session_update(&mut self, update: SessionUpdate) {
        match update {
            SessionUpdate::Server(gid) => {
                self.publish_servers();
                if self.server.as_deref() == Some(gid.as_str()) {
                    self.publish_server_keep_channel();
                }
            }
            SessionUpdate::Channel { gid, channel_id } => {
                if self.server.as_deref() == Some(gid.as_str()) && self.channel.as_deref() == Some(channel_id.as_str()) {
                    self.publish_timeline();
                }
            }
            SessionUpdate::Dm(_) => {}
        }
    }

    fn refresh_all(&mut self) {
        self.publish_servers();
        self.publish_server_keep_channel();
    }

    fn publish_servers(&mut self) {
        let gids: Vec<String> = self
            .session
            .servers()
            .unwrap_or_default()
            .into_iter()
            .filter(|g| !self.session.server(g).ok().flatten().is_some_and(|s| s.metadata.deleted))
            .collect();
        let items: Vec<ServerItem> = gids
            .iter()
            .map(|gid| {
                let name = self
                    .session
                    .server(gid)
                    .ok()
                    .flatten()
                    .map(|s| s.metadata.name.clone())
                    .filter(|n| !n.is_empty())
                    .unwrap_or_else(|| "…".into());
                ServerItem { gid: gid.clone(), initials: initials(&name), name }
            })
            .collect();
        if self.server.is_none() {
            self.server = items.first().map(|s| s.gid.clone());
            if self.server.is_some() {
                Cx::post_action(Update::Servers(items));
                self.publish_server();
                return;
            }
        }
        if items.is_empty() {
            Cx::post_action(Update::Empty);
        }
        Cx::post_action(Update::Servers(items));
    }

    /// New server selected: first text channel.
    fn publish_server(&mut self) {
        self.channel = None;
        self.publish_server_keep_channel();
    }

    fn publish_server_keep_channel(&mut self) {
        let Some(gid) = self.server.clone() else { return };
        let Ok(Some(state)) = self.session.server(&gid) else { return };

        // Rails' order: root channels and categories interleaved by
        // position, each category's channels under it. Channels we can't
        // read are hidden, as Rails does.
        let me = self.session.keys().public_key();
        let readable = |c: &inferno_core::server::wire::Channel| state.can_read(&me, c);
        let row = |c: &inferno_core::server::wire::Channel| SidebarRow::Channel {
            id: c.id.clone(),
            name: c.name.clone(),
            voice: c.kind == "voice",
            encrypted: c.encrypted,
            category: c.category.clone(),
        };
        let mut sidebar = Vec::new();
        for item in inferno_core::server::order::root_items(&state.structure) {
            match item {
                inferno_core::server::order::RootItem::Channel(id) => {
                    if let Some(c) = state.channel(&id).filter(|c| readable(c)) {
                        sidebar.push(row(c));
                    }
                }
                inferno_core::server::order::RootItem::Category(id) => {
                    let name = state.structure.categories.iter().find(|c| c.id == id).map(|c| c.name.to_uppercase()).unwrap_or_default();
                    sidebar.push(SidebarRow::Category { id: id.clone(), name });
                    for cid in inferno_core::server::order::in_category(&state.structure, &id) {
                        if let Some(c) = state.channel(&cid).filter(|c| readable(c)) {
                            sidebar.push(row(c));
                        }
                    }
                }
            }
        }

        // Members: hoisted roles first (highest position), then everyone else.
        let mut by_role: HashMap<Option<String>, Vec<&inferno_core::server::Member>> = HashMap::new();
        for m in state.sorted_members() {
            let hoisted = state
                .roles
                .iter()
                .filter(|r| r.hoist && m.roles.contains(&r.id))
                .max_by_key(|r| r.position)
                .map(|r| r.id.clone());
            by_role.entry(hoisted).or_default().push(m);
        }
        let mut members = Vec::new();
        let mut hoisted: Vec<_> = state.roles.iter().filter(|r| r.hoist).collect();
        hoisted.sort_by_key(|r| std::cmp::Reverse(r.position));
        let push_group = |members: &mut Vec<MemberRow>, title: String, color: u32, list: &[&inferno_core::server::Member]| {
            members.push(MemberRow::Header { text: format!("{title} — {}", list.len()), color });
            members.extend(list.iter().map(|m| member_row(&state, &m.pubkey, &me)));
        };
        if let Some(owner) = state.owner.filter(|o| !state.members.contains_key(o)) {
            // The owner has no member event of their own when they made the server here.
            members.push(MemberRow::Header { text: "OWNER — 1".into(), color: 0x878583 });
            members.push(member_row(&state, &owner, &me));
        }
        for r in hoisted {
            if let Some(list) = by_role.get(&Some(r.id.clone())) {
                push_group(&mut members, r.name.to_uppercase(), hex_color(&r.color).unwrap_or(0x878583), list);
            }
        }
        if let Some(list) = by_role.get(&None) {
            push_group(&mut members, "MEMBERS".into(), 0x878583, list);
        }

        let selectable = |id: &String| state.channel(id).is_some_and(|c| c.kind != "voice" && state.can_read(&me, c));
        if self.channel.as_ref().is_none_or(|id| !selectable(id)) {
            self.channel = sidebar.iter().find_map(|r| match r {
                SidebarRow::Channel { id, voice: false, .. } => Some(id.clone()),
                _ => None,
            });
        }
        let perms = ServerPerms {
            manage_channels: state.has(&me, inferno_core::server::Permission::ManageChannels),
            manage_server: state.has(&me, inferno_core::server::Permission::ManageServer),
            manage_roles: state.has(&me, inferno_core::server::Permission::ManageRoles),
            manage_messages: state.has(&me, inferno_core::server::Permission::ManageMessages),
            kick_members: state.has(&me, inferno_core::server::Permission::KickMembers),
            ban_members: state.has(&me, inferno_core::server::Permission::BanMembers),
            create_invite: state.has(&me, inferno_core::server::Permission::CreateInvite),
            owner: state.is_owner(&me),
        };
        let roles = state.roles.iter().map(|r| RoleItem { id: r.id.clone(), name: r.name.clone() }).collect();
        let mut cats = state.structure.categories.clone();
        cats.sort_by_key(|c| c.position);
        let categories = cats.into_iter().map(|c| RoleItem { id: c.id, name: c.name }).collect();
        let channels = state
            .structure
            .channels
            .iter()
            .map(|c| ChannelForm {
                id: Some(c.id.clone()),
                name: c.name.clone(),
                topic: c.topic.clone(),
                voice: c.kind == "voice",
                category: c.category.clone(),
                encrypted: c.encrypted,
                allowed_roles: inferno_core::server::state::allowed_role_ids(c),
                post_only: c.post_only,
                nsfw: c.nsfw,
            })
            .collect();
        let mut role_forms: Vec<RoleForm> = state
            .roles
            .iter()
            .map(|r| RoleForm {
                id: r.id.clone(),
                name: r.name.clone(),
                color: r.color.clone(),
                position: r.position,
                hoist: r.hoist,
                mentionable: r.mentionable,
                perms: r.permissions.iter().filter(|(_, v)| v.as_bool() == Some(true)).map(|(k, _)| k.clone()).collect(),
                everyone: r.is_everyone(),
            })
            .collect();
        role_forms.sort_by_key(|r| std::cmp::Reverse(r.position));
        let bans = state
            .bans
            .iter()
            .map(|(pk, b)| BanItem { pubkey: pk.to_hex(), name: display(&state, pk).name, reason: b.reason.clone() })
            .collect();
        let m = &state.metadata;
        Cx::post_action(Update::ServerSettings(ServerSettings {
            name: m.name.clone(),
            about: m.about.clone(),
            discoverable: m.discoverable,
            age_restricted: m.age_restricted,
            welcome_enabled: m.welcome_enabled,
            welcome_message: m.welcome_message.clone(),
            roles: role_forms,
            bans,
        }));
        Cx::post_action(Update::Server {
            gid: gid.clone(),
            name: state.metadata.name.clone(),
            sidebar,
            members,
            perms,
            roles,
            categories,
            channels,
        });
        self.publish_channel();
    }

    fn publish_channel(&mut self) {
        let (Some(gid), Some(ch)) = (self.server.clone(), self.channel.clone()) else { return };
        let Ok(Some(state)) = self.session.server(&gid) else { return };
        let Some(c) = state.channel(&ch) else { return };
        Cx::post_action(Update::Channel {
            gid: gid.clone(),
            channel_id: ch.clone(),
            name: c.name.clone(),
            topic: c.topic.clone(),
            encrypted: c.encrypted,
        });
        self.publish_timeline();
    }

    fn publish_timeline(&mut self) {
        let (Some(gid), Some(ch)) = (self.server.clone(), self.channel.clone()) else { return };
        let Ok(Some(state)) = self.session.server(&gid) else { return };
        let Ok(timeline) = self.session.timeline(&gid, &ch) else { return };
        let by_id: HashMap<EventId, usize> = timeline.iter().enumerate().map(|(i, m)| (m.id, i)).collect();
        let mut rows = Vec::with_capacity(timeline.len());
        for (i, m) in timeline.iter().enumerate() {
            let d = display(&state, &m.author);
            let prev = i.checked_sub(1).map(|p| &timeline[p]);
            let grouped = prev.is_some_and(|p| p.author == m.author && m.reply_to.is_none() && m.created_at - p.created_at < 300);
            let reply = m.reply_to.and_then(|id| by_id.get(&id)).map(|&pi| {
                let p = &timeline[pi];
                let cut: String = p.content.as_deref().unwrap_or("…").chars().take(60).collect();
                format!("↳ {}  {}", display(&state, &p.author).name, cut)
            });
            rows.push(MessageRow {
                id: m.id.to_hex(),
                own: m.author == self.session.keys().public_key(),
                reply_to: m.reply_to.map(|r| r.to_hex()),
                initial: first_initial(&d.name),
                author: d.name,
                color: d.color,
                avatar: d.avatar,
                at: m.created_at,
                body: m.content.clone(),
                reply,
                edited: m.edited_at.is_some(),
                pinned: m.pinned,
                grouped,
                system: false,
            });
        }
        let can_pin = state.has(&self.session.keys().public_key(), inferno_core::server::Permission::ManageMessages);
        Cx::post_action(Update::Timeline { gid, channel_id: ch, rows, can_pin });
    }
}
