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
    Category(String),
    Channel { id: String, name: String, voice: bool, encrypted: bool },
}

#[derive(Debug, Clone, PartialEq)]
pub enum MemberRow {
    Header { text: String, color: u32 },
    Member { name: String, initial: String, color: u32, avatar: u32 },
}

#[derive(Debug, Clone, PartialEq)]
pub struct MessageRow {
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

#[derive(Debug, Clone)]
pub enum Update {
    Ready { name: String, npub: String, backed_up: bool },
    Servers(Vec<ServerItem>),
    Server { gid: String, name: String, sidebar: Vec<SidebarRow>, members: Vec<MemberRow> },
    Channel { gid: String, channel_id: String, name: String, topic: String, encrypted: bool },
    Timeline { gid: String, channel_id: String, rows: Vec<MessageRow> },
    Invite(String),
    Error(String),
    /// Nothing selected: no servers yet.
    Empty,
}

#[derive(Debug)]
pub enum Command {
    SelectServer(String),
    SelectChannel(String),
    Send(String),
    CreateServer(String),
    Join(String),
    CreateInvite,
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

fn load_identity() -> Result<(Identity, bool), String> {
    let service = match profile().as_str() {
        "default" => "inferno".to_owned(),
        p => format!("inferno-{p}"),
    };
    let vault = Vault::new(OsKeyring::with_service(&service).map_err(|e| e.to_string())?);
    if let Some(id) = vault.active().map_err(|e| e.to_string())? {
        let backed_up = vault.has_backup(&id.pubkey_hex()).map_err(|e| e.to_string())?;
        return Ok((id, backed_up));
    }
    // First run: no onboarding screen yet, so create a key now and keep it;
    // the backup step comes with onboarding.
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
    let (identity, backed_up) = load_identity()?;
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

    let short = identity.npub()[..12].to_owned();
    Cx::post_action(Update::Ready { name: short, npub: identity.npub(), backed_up });

    let mut ui = Backend { session: session.clone(), server: None, channel: None };
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

fn member_row(state: &ServerState, pk: &PublicKey) -> MemberRow {
    let d = display(state, pk);
    MemberRow::Member { initial: first_initial(&d.name), name: d.name, color: d.color, avatar: d.avatar }
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
            Command::Send(text) => {
                let (Some(gid), Some(ch)) = (self.server.clone(), self.channel.clone()) else {
                    return Err("Pick a channel first.".into());
                };
                self.session
                    .send(&gid, &ch, &Outgoing { content: &text, ..Default::default() })
                    .await
                    .map_err(|e| e.to_string())?;
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
            Command::CreateInvite => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let link = self.session.create_invite(&gid).await.map_err(|e| e.to_string())?;
                Cx::post_action(Update::Invite(link));
            }
        }
        Ok(())
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
        let gids = self.session.servers().unwrap_or_default();
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

        // Uncategorized channels first, then each category, by position.
        let mut channels = state.structure.channels.clone();
        channels.sort_by_key(|c| c.position);
        let mut categories = state.structure.categories.clone();
        categories.sort_by_key(|c| c.position);
        let row = |c: &inferno_core::server::wire::Channel| SidebarRow::Channel {
            id: c.id.clone(),
            name: c.name.clone(),
            voice: c.kind == "voice",
            encrypted: c.encrypted,
        };
        let mut sidebar: Vec<SidebarRow> = channels.iter().filter(|c| c.category.is_none() && c.parent.is_none()).map(row).collect();
        for cat in &categories {
            sidebar.push(SidebarRow::Category(cat.name.to_uppercase()));
            sidebar.extend(channels.iter().filter(|c| c.category.as_deref() == Some(cat.id.as_str())).map(row));
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
            members.extend(list.iter().map(|m| member_row(&state, &m.pubkey)));
        };
        if let Some(owner) = state.owner.filter(|o| !state.members.contains_key(o)) {
            // The owner has no member event of their own when they made the server here.
            members.push(MemberRow::Header { text: "OWNER — 1".into(), color: 0x878583 });
            members.push(member_row(&state, &owner));
        }
        for r in hoisted {
            if let Some(list) = by_role.get(&Some(r.id.clone())) {
                push_group(&mut members, r.name.to_uppercase(), hex_color(&r.color).unwrap_or(0x878583), list);
            }
        }
        if let Some(list) = by_role.get(&None) {
            push_group(&mut members, "MEMBERS".into(), 0x878583, list);
        }

        if self.channel.as_ref().is_none_or(|id| state.channel(id).is_none()) {
            self.channel = state
                .structure
                .channels
                .iter()
                .filter(|c| c.kind != "voice")
                .min_by_key(|c| c.position)
                .map(|c| c.id.clone());
        }
        Cx::post_action(Update::Server { gid: gid.clone(), name: state.metadata.name.clone(), sidebar, members });
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
        Cx::post_action(Update::Timeline { gid, channel_id: ch, rows });
    }
}
