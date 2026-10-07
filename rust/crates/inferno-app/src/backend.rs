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
use inferno_core::server::wire::MemberProfile;
use inferno_core::server::ServerState;
use inferno_core::session::{Session, StartOptions, Update as SessionUpdate};
use inferno_core::gifs::Gif;
use inferno_core::social::{Friendship, Payload};
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
    pub picture: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum SidebarRow {
    Category { id: String, name: String },
    Channel {
        id: String,
        name: String,
        voice: bool,
        encrypted: bool,
        category: Option<String>,
        /// Nesting under hearths (Rails' embers): 0 at the top.
        depth: u8,
        /// Last ember of its hearth: the connector ends here.
        last: bool,
        /// Per level above, whether that level's line runs on past this row.
        guides: Vec<bool>,
    },
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
    pub manage_invites: bool,
    pub create_emojis: bool,
    pub create_stickers: bool,
    pub manage_emojis: bool,
    pub owner: bool,
    pub send_custom_emojis: bool,
    pub send_custom_stickers: bool,
    pub send_gifs: bool,
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
    /// Permission keys that are on (Rails' names), counting the
    /// on-by-default ones unless the role turns them off.
    pub perms: Vec<String>,
    pub everyone: bool,
    /// Kept as published (Rails' `role_type`, e.g. voice providers).
    pub role_type: String,
    /// The permissions map as published, so keys this app doesn't edit
    /// survive a save.
    pub raw_perms: serde_json::Map<String, serde_json::Value>,
    pub member_count: usize,
    /// Members may pick it during onboarding.
    pub self_assignable: bool,
}

/// The permissions map to publish for an edited role: what was published,
/// with every key the editor shows set from the form. On-by-default keys
/// that are off are written as false (leaving them out would turn them back
/// on); keys the editor doesn't know survive.
pub fn role_permissions(f: &RoleForm) -> serde_json::Map<String, serde_json::Value> {
    let mut map = f.raw_perms.clone();
    for (_, perms) in crate::lists::PERMISSION_GROUPS {
        for (k, _) in *perms {
            if f.perms.iter().any(|p| p == k) {
                map.insert((*k).to_owned(), serde_json::Value::Bool(true));
            } else if DEFAULT_ON.contains(k) {
                map.insert((*k).to_owned(), serde_json::Value::Bool(false));
            } else {
                map.remove(*k);
            }
        }
    }
    map
}

#[cfg(test)]
mod role_tests {
    use super::*;
    use serde_json::{json, Value};

    #[test]
    fn saving_keeps_off_defaults_and_unknown_keys() {
        let raw = json!({"send_gifs": false, "voice_provider": true, "kick_members": true}).as_object().unwrap().clone();
        let f = RoleForm { perms: vec!["send_messages".into()], raw_perms: raw, ..Default::default() };
        let m = role_permissions(&f);
        assert_eq!(m.get("send_messages"), Some(&Value::Bool(true)));
        assert_eq!(m.get("send_gifs"), Some(&Value::Bool(false)), "off stays off");
        assert_eq!(m.get("send_custom_emojis"), Some(&Value::Bool(false)));
        assert_eq!(m.get("voice_provider"), Some(&Value::Bool(true)), "not ours to drop");
        assert!(!m.contains_key("kick_members"), "turned off");
    }
}

/// Rails' permissions that are on unless a role sets them to false.
pub const DEFAULT_ON: [&str; 3] = ["send_gifs", "send_custom_emojis", "send_custom_stickers"];

#[derive(Debug, Clone, PartialEq)]
pub struct BanItem {
    pub pubkey: String,
    pub name: String,
    pub reason: String,
}

/// A member as the Members page lists them (Rails' members list).
#[derive(Debug, Clone, PartialEq)]
pub struct MemberInfo {
    pub pubkey: String,
    pub name: String,
    pub initial: String,
    pub avatar: u32,
    pub picture: Option<String>,
    /// (name, colour) of each role, highest first.
    pub roles: Vec<(String, u32)>,
    pub role_ids: Vec<String>,
    pub joined_at: Option<i64>,
    pub timed_out_until: Option<i64>,
    pub owner: bool,
    pub me: bool,
}

/// One audit log line: who, what, when, and Rails' colour for the kind.
#[derive(Debug, Clone, PartialEq)]
pub struct AuditItem {
    pub actor: String,
    pub text: String,
    pub at: i64,
    /// Rails' badge colours: 0 blue, 1 purple, 2 green, 3 amber, 4 red, 5 cyan.
    pub tone: u8,
}

/// What Rails' onboarding wizard shows a new member.
#[derive(Debug, Clone, PartialEq)]
pub struct Onboarding {
    pub gid: String,
    pub name: String,
    pub about: String,
    pub picture: Option<String>,
    pub rules: Vec<String>,
    /// Self-assignable roles: (id, name, colour, already ours).
    pub roles: Vec<(String, String, u32, bool)>,
    /// Highlighted channels (or the first five text channels): names.
    pub channels: Vec<String>,
    /// A preview from settings: finishing changes nothing.
    pub preview: bool,
}

/// A custom emoji or sticker, as the Expression pages list them.
#[derive(Debug, Clone, PartialEq)]
pub struct CustomItem {
    pub name: String,
    pub description: String,
    pub url: String,
    pub by: String,
}

/// An active invite, as Rails' invites page lists it.
#[derive(Debug, Clone, PartialEq)]
pub struct InviteItem {
    pub code: String,
    pub link: String,
    pub by: String,
    pub created_at: i64,
    pub uses: u32,
    /// 0 = unlimited.
    pub max_uses: u32,
    /// 0 = never.
    pub expires_at: i64,
    pub can_revoke: bool,
}

/// Everything the server settings pages show.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct ServerSettings {
    pub name: String,
    pub about: String,
    pub picture: String,
    pub banner: String,
    /// Flutter's catalog tag: community, friends_family, gaming, work_team, adult.
    pub server_type: String,
    pub discoverable: bool,
    pub age_restricted: bool,
    pub welcome_enabled: bool,
    pub welcome_message: String,
    /// `None` = the first text channel (Rails' "Default (#general)").
    pub welcome_channel: Option<String>,
    /// Text channels by position, for the welcome channel choice.
    pub text_channels: Vec<RoleItem>,
    pub member_count: usize,
    /// Newest first.
    pub invites: Vec<InviteItem>,
    /// Owner first, then by name.
    pub members: Vec<MemberInfo>,
    pub emojis: Vec<CustomItem>,
    pub stickers: Vec<CustomItem>,
    /// Newest first, at most 200.
    pub audit: Vec<AuditItem>,
    /// Onboarding: on, rules one per line, highlighted channel ids.
    pub onboarding: bool,
    pub rules: Vec<String>,
    pub highlights: Vec<String>,
    /// Rails' server relays (in the metadata), and ours they add to.
    pub server_relays: Vec<String>,
    pub global_relays: Vec<String>,
    pub voice_enabled: bool,
    /// Names of the members whose LiveKit accounts power voice (Rails).
    pub voice_providers: Vec<String>,
    pub me_provider: bool,
    pub afk_channel: Option<String>,
    /// Minutes; 0 = off.
    pub afk_timeout: u32,
    /// "move" or "kick".
    pub afk_action: String,
    /// Voice channels by sidebar order: (id, name, summary).
    pub voice_channels: Vec<(String, String, String)>,
    /// Our highest role position (Flutter's hierarchy rule: we may edit,
    /// reorder and hand out only roles below it); `i64::MAX` for the owner.
    pub my_rank: i64,
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
    /// Voice: Rails' Hearth (the voice channel this one nests under).
    pub hearth: Option<String>,
    pub voice_bitrate: u32,
    pub voice_user_limit: u32,
    pub video_enabled: bool,
    /// How deep it sits (0 = top); a hearth must be at depth 0 or 1.
    pub depth: u8,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MemberRow {
    Header { text: String, color: u32 },
    Member {
        name: String,
        initial: String,
        color: u32,
        avatar: u32,
        picture: Option<String>,
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
    /// The author's pubkey (hex), for the profile card.
    pub author_pk: String,
    /// The parent's event id, for jump-to-reply.
    pub reply_to: Option<String>,
    pub author: String,
    pub initial: String,
    pub color: u32,
    pub avatar: u32,
    pub picture: Option<String>,
    pub at: i64,
    /// `None` = encrypted and we don't have the key.
    pub body: Option<String>,
    pub reply: Option<String>,
    pub edited: bool,
    pub pinned: bool,
    /// Same author, under 5 minutes, not a reply: drawn without the header.
    pub grouped: bool,
    pub system: bool,
    /// The first invite link in the body and its card (Rails' embed).
    pub invite: Option<(String, InviteCard)>,
}

/// An invite link's card, as it resolves.
#[derive(Debug, Clone, PartialEq)]
pub enum InviteCard {
    Loading,
    /// Nothing on our relays answers for it.
    Unavailable,
    Ready(inferno_core::session::InvitePreview),
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
    pub picture: String,
    pub banner: String,
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

/// Rails' Contact status, as the UI needs it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Friend {
    #[default]
    None,
    Outgoing,
    Incoming,
    Accepted,
}

impl From<Friendship> for Friend {
    fn from(f: Friendship) -> Self {
        match f {
            Friendship::None => Friend::None,
            Friendship::Outgoing => Friend::Outgoing,
            Friendship::Incoming => Friend::Incoming,
            Friendship::Accepted => Friend::Accepted,
        }
    }
}

/// Someone outside a server: a DM peer, friend, request or block.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Person {
    pub pubkey: String,
    pub name: String,
    pub initial: String,
    pub avatar: u32,
    /// Profile picture URL; the letter avatar shows until (or unless) it loads.
    pub picture: Option<String>,
}

/// A row of the DM sidebar.
#[derive(Debug, Clone, PartialEq)]
pub struct DmRow {
    pub person: Person,
    pub unread: usize,
    pub request: bool,
    pub friend: Friend,
}

/// Everything the Home view shows (Rails' conversations#index and the DM
/// sidebar).
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Home {
    pub conversations: Vec<DmRow>,
    pub friends: Vec<Person>,
    pub incoming: Vec<Person>,
    pub outgoing: Vec<Person>,
    pub blocked: Vec<Person>,
    /// The Home button's badge: friend requests plus unread DMs.
    pub badge: usize,
}

/// Rails' profile card (`users/_card`), for one member of the open server.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Card {
    pub pubkey: String,
    pub npub: String,
    pub name: String,
    /// Rails' `tag`: the username.
    pub tag: String,
    pub initial: String,
    pub status: String,
    pub about: String,
    /// Body: profile_color → profile_color_2 at 135° (`#1e1c1b` without one).
    pub color: u32,
    pub color_2: u32,
    /// Avatar ring: profile_color_2, else profile_color, else `#1e1c1b`.
    pub ring: u32,
    pub avatar: u32,
    pub picture: Option<String>,
    pub banner: Option<String>,
    /// (name, color), in role order, without @everyone.
    pub roles: Vec<(String, u32)>,
    pub joined_at: Option<i64>,
    pub me: bool,
    pub friend: Friend,
    /// Opened outside a server (Rails shows Friends Since instead).
    pub in_server: bool,
}

#[derive(Debug, Clone)]
pub enum Update {
    Card(Card),
    Home(Home),
    /// The open DM: who, and whether it's a request waiting for an answer
    /// (with how many messages). Rows come as a `Timeline` keyed "@dm".
    DmHeader { person: Person, request: Option<usize> },
    People(Vec<Person>),
    /// Custom emoji and stickers of every server we're in (Rails' picker
    /// offers them across servers).
    EmojiSets(Vec<crate::picker::ServerSet>),
    GifLibrary { favorites: Vec<Gif>, collections: Vec<inferno_core::gifs::Collection> },
    /// The `Authorization` header for upload `id`, and the servers to try.
    UploadAuth { id: u64, header: String, servers: Vec<String> },
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
    /// `mentions`: lowercase `@word` → its `mention:` target (see
    /// message_format), for the names that resolve here.
    Timeline { gid: String, channel_id: String, rows: Vec<MessageRow>, can_pin: bool, mentions: Vec<(String, String)> },
    Invite(String),
    Discovery(Vec<inferno_core::session::Listing>),
    Onboarding(Onboarding),
    /// (pubkey hex, name, last activity we know of).
    PrunePreview(Vec<(String, String, Option<i64>)>),
    Error(String),
    /// Something worked (a green notification).
    Notice(String),
    /// Nothing selected: no servers yet.
    Empty,
}

#[derive(Debug)]
pub enum Command {
    SelectServer(String),
    SelectChannel(String),
    Send { text: String, reply_to: Option<String>, spoiler: bool },
    /// A sticker, sent as its own message.
    SendSticker(String),
    GifLibrary,
    ToggleGifFavorite(Gif),
    CreateGifCollection(String),
    ToggleGifInCollection { id: String, gif: Gif },
    DeleteGifCollection(String),
    Edit { id: String, text: String },
    Pin { id: String, pinned: bool },
    CreateServer { name: String, server_type: String },
    /// Public servers on our relays (answers with `Discovery`).
    Discover,
    JoinPublic { gid: String, owner: String },
    Join(String),
    /// `max_uses` 0 = unlimited, `expires_in` seconds, 0 = never.
    CreateInvite { max_uses: u32, expires_in: i64 },
    RevokeInvite(String),
    /// Members inactive for `days` (answers with `PrunePreview`).
    PrunePreview { days: i64, include_roles: bool },
    AddEmoji { name: String, url: String },
    RemoveEmoji(String),
    AddSticker { name: String, description: String, url: String },
    RemoveSticker(String),
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
    /// Nest a voice channel under a hearth (or out of one with `None`).
    NestChannel { id: String, hearth: Option<String>, index: Option<usize> },
    MoveCategory { id: String, index: usize },
    AddServerRelay(String),
    SaveOnboarding { enabled: bool, rules: Vec<String>, highlights: Vec<String>, self_assignable: Vec<String> },
    PreviewOnboarding,
    /// Done with the wizard: the roles picked.
    FinishOnboarding { gid: String, roles: Vec<String> },
    RemoveServerRelay(String),
    SaveVoice { enabled: bool, afk_channel: Option<String>, afk_timeout: u32, afk_action: String },
    /// Add or remove ourselves as a voice provider.
    VoiceProvider(bool),
    LeaveServer,
    MarkRead(String),
    DeleteMessage(String),
    Search(String),
    SetTheme(String),
    /// Opens the profile card of a member (hex pubkey).
    Card(String),
    /// Home: the DM sidebar and friends page.
    Home,
    OpenDm(String),
    AddFriend(String),
    AnswerFriend { pubkey: String, accept: bool },
    RemoveFriend(String),
    IgnoreFriend(String),
    Block(String),
    Unblock(String),
    AcceptDm(String),
    CloseDm(String),
    MarkDmRead(String),
    FindPeople(String),
    /// Sign an upload of a blob with this sha256 (hex); `id` is echoed.
    UploadAuth { id: u64, sha256: String },
    SaveBlossomServers(Vec<String>),
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

    let (preview_tx, mut preview_rx) = mpsc::unbounded_channel();
    let mut ui = Backend {
        session: session.clone(),
        server: None,
        channel: None,
        home: false,
        dm: None,
        vault,
        npub: identity.npub(),
        backed_up,
        previews: HashMap::new(),
        preview_tx,
        wizard_shown: Default::default(),
    };
    if let Ok(Some(serde_json::Value::String(theme))) = session.synced_setting("theme") {
        Cx::post_action(Update::Theme(theme));
    }
    ui.publish_me();
    ui.publish_home();
    ui.publish_gifs();
    ui.publish_relays();
    ui.publish_servers();

    let mut updates = session.updates();
    // Profiles arrive in bursts (hundreds at startup): one refresh per burst.
    let mut people_due: Option<tokio::time::Instant> = None;
    loop {
        tokio::select! {
            cmd = commands.recv() => {
                let Some(cmd) = cmd else { break };
                if let Err(e) = ui.command(cmd).await {
                    Cx::post_action(Update::Error(e));
                }
            }
            Some((link, card)) = preview_rx.recv() => {
                ui.previews.insert(link, card);
                ui.republish_messages();
            }
            _ = async { tokio::time::sleep_until(people_due.expect("guarded")).await }, if people_due.is_some() => {
                people_due = None;
                ui.refresh_people();
            }
            update = updates.recv() => match update {
                Ok(SessionUpdate::Profile(_)) => {
                    people_due.get_or_insert_with(|| tokio::time::Instant::now() + std::time::Duration::from_millis(300));
                }
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
    /// In Home (DMs and friends) rather than a server.
    home: bool,
    dm: Option<PublicKey>,
    vault: Vault<OsKeyring>,
    npub: String,
    backed_up: bool,
    /// Invite cards by link, resolved once each (relays rate-limit).
    previews: HashMap<String, InviteCard>,
    preview_tx: mpsc::UnboundedSender<(String, InviteCard)>,
    /// Servers whose onboarding wizard we've shown this session.
    wizard_shown: std::collections::HashSet<String>,
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

fn member_row(state: &ServerState, pk: &PublicKey, me: &PublicKey, people: &People) -> MemberRow {
    let d = display(state, pk, people);
    MemberRow::Member {
        initial: first_initial(&d.name),
        name: d.name,
        color: d.color,
        avatar: d.avatar,
        picture: d.picture,
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

/// A name `@word` can match (Rails: `@(\w+)`).
fn is_word(name: &str) -> bool {
    !name.is_empty() && name.chars().all(|c| c.is_alphanumeric() || c == '_')
}

/// Rails styles `@username` for members and `@role` for roles (in the role's
/// colour). Display names and nicknames that are one word count too, since
/// that's what our Mention inserts.
fn server_mentions(state: &ServerState, people: &People) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for role in state.roles.iter().filter(|r| !r.is_everyone()) {
        let name = role.name.trim_start_matches('@');
        if is_word(name) {
            let color = role.color.trim_start_matches('#');
            let color = if color.len() == 6 { color } else { "dc2626" };
            out.push((name.to_lowercase(), format!("role:{color}")));
        }
    }
    for (pk, m) in &state.members {
        let p = people.get(pk);
        for name in [Some(&p.name), Some(&p.display_name), m.nickname.as_ref()].into_iter().flatten() {
            if is_word(name) {
                out.push((name.to_lowercase(), pk.to_hex()));
            }
        }
    }
    out
}

fn card(state: &ServerState, pk: &PublicKey, me: &PublicKey, people: &People) -> Card {
    let d = display(state, pk, people);
    let m = state.members.get(pk);
    let profile = people.get(pk);
    let c1 = profile.color.as_deref().and_then(hex_color);
    let c2 = profile.color_2.as_deref().and_then(hex_color);
    let mut roles: Vec<_> = state
        .roles
        .iter()
        .filter(|r| !r.is_everyone() && m.is_some_and(|m| m.roles.contains(&r.id)))
        .collect();
    roles.sort_by_key(|r| std::cmp::Reverse(r.position));
    let status = [profile.status_emoji.as_str(), profile.status.as_str()]
        .iter()
        .filter(|s| !s.is_empty())
        .copied()
        .collect::<Vec<_>>()
        .join(" ");
    let npub = inferno_core::nostr::nips::nip19::ToBech32::to_bech32(pk).unwrap_or_default();
    Card {
        pubkey: pk.to_hex(),
        tag: if profile.name.is_empty() { format!("{}…", &npub[..16.min(npub.len())]) } else { profile.name.clone() },
        npub,
        initial: first_initial(&d.name),
        name: d.name,
        status,
        about: profile.about.clone(),
        color: c1.unwrap_or(DEFAULT_AVATAR),
        color_2: c2.or(c1).unwrap_or(DEFAULT_AVATAR),
        ring: c2.or(c1).unwrap_or(DEFAULT_AVATAR),
        avatar: d.avatar,
        picture: profile.picture.clone(),
        banner: profile.banner.clone(),
        roles: roles.iter().map(|r| (r.name.clone(), hex_color(&r.color).unwrap_or(0x99aab5))).collect(),
        joined_at: m.and_then(|m| m.joined_at),
        me: pk == me,
        friend: Friend::None,
        in_server: true,
    }
}

struct Display {
    name: String,
    color: u32,
    avatar: u32,
    picture: Option<String>,
}

/// Profiles for one pass over the UI: each person's unified profile
/// (`profile::merge`), with the server states loaded once.
struct People<'a> {
    session: &'a Session,
    states: Vec<ServerState>,
    cache: std::cell::RefCell<HashMap<PublicKey, MemberProfile>>,
}

impl<'a> People<'a> {
    fn new(session: &'a Session) -> Self {
        let states = session.servers().unwrap_or_default().iter().filter_map(|g| session.server(g).ok().flatten()).collect();
        People { session, states, cache: Default::default() }
    }

    fn get(&self, pk: &PublicKey) -> MemberProfile {
        if let Some(p) = self.cache.borrow().get(pk) {
            return p.clone();
        }
        let p = inferno_core::sync::profile::merge(
            self.session.profile_of(pk).ok().flatten(),
            self.states.iter().filter_map(|s| s.members.get(pk)).map(|m| &m.profile),
        );
        self.cache.borrow_mut().insert(*pk, p.clone());
        p
    }
}

/// How a member shows up: nickname, display name, profile name, or a pubkey
/// prefix; colored by their highest colored role.
fn display(state: &ServerState, pk: &PublicKey, people: &People) -> Display {
    let m = state.members.get(pk);
    let profile = people.get(pk);
    let name = m
        .and_then(|m| m.nickname.clone())
        .or_else(|| Some(profile.display_name.clone()).filter(|s| !s.is_empty()))
        .or_else(|| Some(profile.name.clone()).filter(|s| !s.is_empty()))
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
    let avatar = profile.color.as_deref().and_then(hex_color).unwrap_or(DEFAULT_AVATAR);
    Display { name, color, avatar, picture: profile.picture.clone() }
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
                self.home = false;
                self.dm = None;
                self.server = Some(gid);
                self.channel = None;
                self.publish_server();
            }
            Command::SelectChannel(id) => {
                self.channel = Some(id);
                self.publish_channel();
            }
            Command::Send { text, spoiler, .. } if self.dm.is_some() => {
                let to = self.dm.expect("checked");
                self.session
                    .send_dm(&to, &Payload::Message { content: text, files: vec![], spoiler })
                    .await
                    .map_err(|e| e.to_string())?;
                self.publish_dm();
            }
            Command::Edit { id, text } if self.dm.is_some() => {
                let to = self.dm.expect("checked");
                let id = EventId::from_hex(&id).map_err(|e| e.to_string())?;
                self.session.send_dm(&to, &Payload::Edit { id, content: text }).await.map_err(|e| e.to_string())?;
                self.publish_dm();
            }
            Command::DeleteMessage(id) if self.dm.is_some() => {
                let to = self.dm.expect("checked");
                let id = EventId::from_hex(&id).map_err(|e| e.to_string())?;
                self.session.send_dm(&to, &Payload::Delete { id }).await.map_err(|e| e.to_string())?;
                self.publish_dm();
            }
            Command::Home => {
                self.home = true;
                self.dm = None;
                self.publish_home();
            }
            Command::OpenDm(pk) => {
                let pk = PublicKey::from_hex(&pk).map_err(|e| e.to_string())?;
                self.home = true;
                self.dm = Some(pk);
                self.session.want_profiles(&[pk]).await;
                self.publish_dm();
                self.publish_home();
            }
            Command::AddFriend(pk) => {
                let pk = PublicKey::from_hex(&pk).map_err(|e| e.to_string())?;
                self.session.add_friend(&pk).await.map_err(|e| e.to_string())?;
                Cx::post_action(Update::Notice("Friend request sent.".into()));
            }
            Command::AnswerFriend { pubkey, accept } => {
                let pk = PublicKey::from_hex(&pubkey).map_err(|e| e.to_string())?;
                self.session.answer_friend(&pk, accept).await.map_err(|e| e.to_string())?;
            }
            Command::RemoveFriend(pk) => {
                let pk = PublicKey::from_hex(&pk).map_err(|e| e.to_string())?;
                self.session.remove_friend(&pk).await.map_err(|e| e.to_string())?;
            }
            Command::IgnoreFriend(pk) => {
                let pk = PublicKey::from_hex(&pk).map_err(|e| e.to_string())?;
                self.session.ignore_friend(&pk).map_err(|e| e.to_string())?;
            }
            Command::Block(pk) => {
                let pk = PublicKey::from_hex(&pk).map_err(|e| e.to_string())?;
                self.session.block(&pk).await.map_err(|e| e.to_string())?;
                if self.dm == Some(pk) {
                    self.dm = None;
                }
                self.publish_home();
            }
            Command::Unblock(pk) => {
                let pk = PublicKey::from_hex(&pk).map_err(|e| e.to_string())?;
                self.session.unblock(&pk).await.map_err(|e| e.to_string())?;
            }
            Command::AcceptDm(pk) => {
                let pk = PublicKey::from_hex(&pk).map_err(|e| e.to_string())?;
                self.session.accept_dm(&pk).map_err(|e| e.to_string())?;
                self.publish_dm();
            }
            Command::CloseDm(pk) => {
                let pk = PublicKey::from_hex(&pk).map_err(|e| e.to_string())?;
                self.session.close_dm(&pk).map_err(|e| e.to_string())?;
                if self.dm == Some(pk) {
                    self.dm = None;
                    self.publish_home();
                }
            }
            Command::MarkDmRead(pk) => {
                let pk = PublicKey::from_hex(&pk).map_err(|e| e.to_string())?;
                self.session.mark_dm_read(&pk).map_err(|e| e.to_string())?;
            }
            Command::UploadAuth { id, sha256 } => {
                let header = inferno_core::blossom::upload_auth(self.session.keys(), &sha256, Timestamp::now())?;
                Cx::post_action(Update::UploadAuth { id, header, servers: self.upload_servers() });
            }
            Command::SaveBlossomServers(servers) => {
                self.session.set_blossom_servers(&servers).await.map_err(|e| e.to_string())?;
            }
            Command::FindPeople(q) => {
                let people = self.find_people(&q).await;
                Cx::post_action(Update::People(people));
            }
            Command::GifLibrary => self.publish_gifs(),
            Command::ToggleGifFavorite(gif) => {
                let on = self.session.toggle_gif_favorite(gif).map_err(|e| e.to_string())?;
                Cx::post_action(Update::Notice(if on { "Added to favorites.".into() } else { "Removed from favorites.".into() }));
                self.publish_gifs();
            }
            Command::CreateGifCollection(name) => {
                self.session.create_gif_collection(&name).map_err(|e| e.to_string())?;
                self.publish_gifs();
            }
            Command::ToggleGifInCollection { id, gif } => {
                self.session.toggle_gif_in_collection(&id, gif).map_err(|e| e.to_string())?;
                self.publish_gifs();
            }
            Command::DeleteGifCollection(id) => {
                self.session.delete_gif_collection(&id).map_err(|e| e.to_string())?;
                self.publish_gifs();
            }
            Command::SendSticker(url) if self.dm.is_some() => {
                let to = self.dm.expect("checked");
                self.session
                    .send_dm(&to, &Payload::Message { content: url, files: vec![], spoiler: false })
                    .await
                    .map_err(|e| e.to_string())?;
                self.publish_dm();
            }
            Command::SendSticker(url) => {
                let (gid, ch) = self.selected()?;
                self.session
                    .send(&gid, &ch, &Outgoing { content: &url, sticker: true, ..Default::default() })
                    .await
                    .map_err(|e| e.to_string())?;
                self.publish_timeline();
            }
            Command::Send { text, reply_to, spoiler } => {
                let (gid, ch) = self.selected()?;
                let reply_to = reply_to.and_then(|id| EventId::from_hex(&id).ok());
                self.session
                    .send(&gid, &ch, &Outgoing { content: &text, reply_to, spoiler, ..Default::default() })
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
            Command::CreateServer { name, server_type } => {
                let gid = self.session.create_server(name.trim()).await.map_err(|e| e.to_string())?;
                if server_type != "community" {
                    self.session
                        .update_metadata(&gid, move |m| {
                            m.age_restricted |= server_type == "adult";
                            m.server_type = server_type;
                        })
                        .await
                        .map_err(|e| e.to_string())?;
                }
                self.server = Some(gid);
                self.channel = None;
                self.publish_servers();
                self.publish_server();
            }
            Command::Discover => {
                let listings = self.session.discover().await.map_err(|e| e.to_string())?;
                Cx::post_action(Update::Discovery(listings));
            }
            Command::JoinPublic { gid, owner } => {
                let owner = PublicKey::from_hex(&owner).map_err(|e| e.to_string())?;
                let gid = self.session.join_public(&gid, &owner).await.map_err(|_| "That server isn't open to join any more.".to_owned())?;
                self.forget_previews(&gid);
                self.home = false;
                self.server = Some(gid);
                self.channel = None;
                self.publish_servers();
                self.publish_server();
            }
            Command::Join(link) => {
                let gid = self.session.join(link.trim()).await.map_err(|e| e.to_string())?;
                self.forget_previews(&gid);
                self.home = false;
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
                        picture: set(&form.picture),
                        banner: set(&form.banner),
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
                            hearth: form.hearth.clone(),
                            voice_bitrate: form.voice_bitrate,
                            voice_user_limit: form.voice_user_limit,
                            video_enabled: form.video_enabled,
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
                                if c.kind == "voice" {
                                    c.parent = f.hearth;
                                    c.voice_bitrate = f.voice_bitrate;
                                    c.voice_user_limit = f.voice_user_limit;
                                    c.video_enabled = f.video_enabled;
                                }
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
            Command::NestChannel { id, hearth, index } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.nest_channel(&gid, &id, hearth.as_deref(), index).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::SaveOnboarding { enabled, rules, highlights, self_assignable } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session
                    .update_metadata(&gid, move |m| {
                        m.onboarding = enabled;
                        m.rules = rules;
                        m.highlights = highlights;
                    })
                    .await
                    .map_err(|e| e.to_string())?;
                let state = self.session.server(&gid).ok().flatten().ok_or("Unknown server.")?;
                let changed = state.roles.iter().any(|r| r.self_assignable != self_assignable.contains(&r.id));
                if changed {
                    let roles = state
                        .roles
                        .iter()
                        .cloned()
                        .map(|mut r| {
                            r.self_assignable = self_assignable.contains(&r.id);
                            r
                        })
                        .collect();
                    self.session.save_roles(&gid, roles).await.map_err(|e| e.to_string())?;
                }
                Cx::post_action(Update::Notice("Onboarding saved.".into()));
                self.publish_server_keep_channel();
            }
            Command::PreviewOnboarding => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                if let Some(o) = self.onboarding(&gid, true) {
                    Cx::post_action(Update::Onboarding(o));
                }
            }
            Command::FinishOnboarding { gid, roles } => {
                self.session.set_self_roles(&gid, &roles).await.map_err(|e| e.to_string())?;
                self.session.mark_onboarded(&gid).map_err(|e| e.to_string())?;
            }
            Command::AddServerRelay(url) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let url = inferno_core::relay::normalize_url(url.trim()).ok_or("That isn't a relay address (wss://…).")?;
                self.session
                    .update_metadata(&gid, move |m| {
                        if !m.relays.contains(&url) {
                            m.relays.push(url);
                        }
                    })
                    .await
                    .map_err(|e| e.to_string())?;
                self.session.resubscribe().await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::RemoveServerRelay(url) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.update_metadata(&gid, move |m| m.relays.retain(|r| *r != url)).await.map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::SaveVoice { enabled, afk_channel, afk_timeout, afk_action } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session
                    .update_metadata(&gid, move |m| {
                        m.voice_enabled = enabled;
                        m.afk_channel = afk_channel;
                        m.afk_timeout_mins = afk_timeout;
                        m.afk_action = afk_action;
                    })
                    .await
                    .map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::VoiceProvider(on) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let me = self.session.keys().public_key();
                self.session
                    .update_metadata(&gid, move |m| {
                        m.voice_providers.retain(|p| *p != me);
                        if on {
                            m.voice_providers.push(me);
                        }
                    })
                    .await
                    .map_err(|e| e.to_string())?;
                self.publish_server_keep_channel();
            }
            Command::MoveCategory { id, index } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.move_category(&gid, &id, index).await.map_err(|e| e.to_string())?;
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
                        m.picture = Some(o.picture).filter(|u| !u.is_empty());
                        m.banner = Some(o.banner).filter(|u| !u.is_empty());
                        m.server_type = o.server_type;
                        m.welcome_channel = o.welcome_channel;
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
                        permissions: role_permissions(&f),
                        id: f.id,
                        name: f.name.trim().to_owned(),
                        color: f.color,
                        position: f.position,
                        hoist: f.hoist,
                        mentionable: f.mentionable,
                        self_assignable: f.self_assignable,
                        role_type: f.role_type,
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
            Command::Card(pk) => {
                let pk = PublicKey::from_hex(&pk).map_err(|e| e.to_string())?;
                let me = self.session.keys().public_key();
                let state = if self.home { None } else { self.server.as_ref().and_then(|g| self.session.server(g).ok().flatten()) };
                let mut c = match state.as_ref().filter(|s| s.is_member(&pk)) {
                    Some(state) => card(state, &pk, &me, &People::new(&self.session)),
                    None => self.outside_card(&pk),
                };
                c.friend = self.session.friendship(&pk).map(Friend::from).unwrap_or_default();
                Cx::post_action(Update::Card(c));
            }
            Command::SetTheme(name) => {
                self.session.set_synced_setting("theme", serde_json::json!(name)).map_err(|e| e.to_string())?;
            }
            Command::Search(text) => {
                let people = People::new(&self.session);
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let mut query = inferno_core::search::Query::parse(&text);
                // before:/after:/on: name days on this device's calendar.
                query.after = query.after.map(crate::time_fmt::local_midnight);
                query.before = query.before.map(crate::time_fmt::local_midnight);
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
                        let d = display(&state, &h.message.author, &people);
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
            Command::CreateInvite { max_uses, expires_in } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let expires_at = if expires_in > 0 { inferno_core::store::now_secs() + expires_in } else { 0 };
                let link = self.session.create_invite(&gid, max_uses, expires_at).await.map_err(|e| e.to_string())?;
                Cx::post_action(Update::Invite(link));
            }
            Command::AddEmoji { name, url } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.add_emoji(&gid, &name, &url).await.map_err(|e| e.to_string())?;
                Cx::post_action(Update::Notice(format!(":{name}: added.")));
            }
            Command::RemoveEmoji(name) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.remove_emoji(&gid, &name).await.map_err(|e| e.to_string())?;
            }
            Command::AddSticker { name, description, url } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.add_sticker(&gid, &name, &description, &url).await.map_err(|e| e.to_string())?;
                Cx::post_action(Update::Notice(format!("Sticker \"{name}\" added.")));
            }
            Command::RemoveSticker(name) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.remove_sticker(&gid, &name).await.map_err(|e| e.to_string())?;
            }
            Command::PrunePreview { days, include_roles } => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                let found = self.session.prune_candidates(&gid, days, include_roles).await.map_err(|e| e.to_string())?;
                let state = self.session.server(&gid).ok().flatten().ok_or("Unknown server.")?;
                let me = self.session.keys().public_key();
                // Flutter's hierarchy rule: nobody at or above our own rank.
                let rank_of = |pk: &PublicKey| {
                    let held = state.members.get(pk).map(|m| m.roles.clone()).unwrap_or_default();
                    state.roles.iter().filter(|r| held.contains(&r.id)).map(|r| r.position).max().unwrap_or(0)
                };
                let mine = if state.is_owner(&me) { i64::MAX } else { rank_of(&me) };
                let people = People::new(&self.session);
                let rows = found
                    .into_iter()
                    .filter(|(pk, _)| rank_of(pk) < mine)
                    .map(|(pk, at)| (pk.to_hex(), display(&state, &pk, &people).name, at))
                    .collect();
                Cx::post_action(Update::PrunePreview(rows));
            }
            Command::RevokeInvite(code) => {
                let gid = self.server.clone().ok_or("Pick a server first.")?;
                self.session.revoke_invite(&gid, &code).await.map_err(|e| e.to_string())?;
                Cx::post_action(Update::Notice("Invite revoked.".into()));
            }
        }
        Ok(())
    }

    /// The person's unified profile (see `People`).
    fn profile(&self, pk: &PublicKey) -> MemberProfile {
        self.session.profile(pk).unwrap_or_default()
    }

    /// Where uploads go. `INFERNO_BLOSSOM=url,url` overrides; a local test
    /// run (`INFERNO_RELAYS` set) defaults to inferno-devrelay's Blossom so
    /// test files never reach public hosts.
    fn upload_servers(&self) -> Vec<String> {
        let split = |v: String| v.split(',').map(|s| s.trim().to_owned()).filter(|s| !s.is_empty()).collect::<Vec<_>>();
        if let Ok(v) = std::env::var("INFERNO_BLOSSOM") {
            return split(v);
        }
        if std::env::var("INFERNO_RELAYS").is_ok() {
            return vec!["http://127.0.0.1:7778".into()];
        }
        self.session.blossom_servers().unwrap_or_default()
    }

    fn person(&self, pk: &PublicKey) -> Person {
        let profile = self.profile(pk);
        let npub = inferno_core::nostr::nips::nip19::ToBech32::to_bech32(pk).unwrap_or_default();
        let name = [profile.display_name.clone(), profile.name.clone()]
            .into_iter()
            .find(|n| !n.is_empty())
            .unwrap_or_else(|| format!("{}…", &npub[..12.min(npub.len())]));
        let name = if *pk == self.session.keys().public_key() { "Saved Messages".to_owned() } else { name };
        Person {
            pubkey: pk.to_hex(),
            initial: first_initial(&name),
            name,
            avatar: profile.color.as_deref().and_then(hex_color).unwrap_or(DEFAULT_AVATAR),
            picture: profile.picture.clone(),
        }
    }

    fn outside_card(&self, pk: &PublicKey) -> Card {
        let profile = self.profile(pk);
        let p = self.person(pk);
        let npub = inferno_core::nostr::nips::nip19::ToBech32::to_bech32(pk).unwrap_or_default();
        let c1 = profile.color.as_deref().and_then(hex_color);
        let c2 = profile.color_2.as_deref().and_then(hex_color);
        let status = [profile.status_emoji.as_str(), profile.status.as_str()]
            .iter()
            .filter(|s| !s.is_empty())
            .copied()
            .collect::<Vec<_>>()
            .join(" ");
        Card {
            pubkey: pk.to_hex(),
            tag: if profile.name.is_empty() { format!("{}…", &npub[..16.min(npub.len())]) } else { profile.name.clone() },
            npub,
            initial: p.initial,
            name: p.name,
            status,
            about: profile.about.clone(),
            color: c1.unwrap_or(DEFAULT_AVATAR),
            color_2: c2.or(c1).unwrap_or(DEFAULT_AVATAR),
            ring: c2.or(c1).unwrap_or(DEFAULT_AVATAR),
            avatar: p.avatar,
            picture: profile.picture.clone(),
            banner: profile.banner.clone(),
            roles: vec![],
            joined_at: None,
            me: *pk == self.session.keys().public_key(),
            friend: Friend::None,
            in_server: false,
        }
    }

    fn publish_home(&mut self) {
        let friends = self.session.friendships().unwrap_or_default();
        let conversations = self.session.conversations().unwrap_or_default();
        let pick = |want: Friendship| -> Vec<Person> {
            let mut v: Vec<Person> = friends.iter().filter(|(_, f)| **f == want).map(|(pk, _)| self.person(pk)).collect();
            v.sort_by_key(|p| p.name.to_lowercase());
            v
        };
        let mut blocked: Vec<Person> = self.session.blocked_list().unwrap_or_default().iter().map(|pk| self.person(pk)).collect();
        blocked.sort_by_key(|p| p.name.to_lowercase());
        let incoming = pick(Friendship::Incoming);
        let unread: usize = conversations.iter().map(|c| c.unread).sum();
        let home = Home {
            conversations: conversations
                .iter()
                .map(|c| DmRow {
                    person: self.person(&c.with),
                    unread: c.unread,
                    request: c.request,
                    friend: friends.get(&c.with).copied().map(Friend::from).unwrap_or_default(),
                })
                .collect(),
            friends: pick(Friendship::Accepted),
            badge: incoming.len() + unread,
            incoming,
            outgoing: pick(Friendship::Outgoing),
            blocked,
        };
        Cx::post_action(Update::Home(home));
    }

    /// The open DM, as a timeline keyed ("@dm", pubkey).
    fn publish_dm(&mut self) {
        let Some(with) = self.dm else { return };
        let me = self.session.keys().public_key();
        let messages = self.session.dm_messages(&with).unwrap_or_default();
        let person = self.person(&with);
        let me_person = self.person(&me);
        let my_name = if with == me {
            me_person.name.clone()
        } else {
            let p = self.session.my_profile().unwrap_or_default();
            let s = |k: &str| p.get(k).and_then(|v| v.as_str()).unwrap_or_default().to_owned();
            [s("display_name"), s("name")].into_iter().find(|n| !n.is_empty()).unwrap_or_else(|| self.npub[..12].to_owned())
        };
        let request = self
            .session
            .conversations()
            .unwrap_or_default()
            .into_iter()
            .find(|c| c.with == with && c.request)
            .map(|_| messages.len());
        let mut rows = Vec::with_capacity(messages.len());
        for (i, m) in messages.iter().enumerate() {
            let prev = i.checked_sub(1).map(|p| &messages[p]);
            let grouped = prev.is_some_and(|p| p.author == m.author && m.created_at - p.created_at < 300);
            let (name, avatar) = if m.author == me { (my_name.clone(), me_person.avatar) } else { (person.name.clone(), person.avatar) };
            let invite = self.invite_card(&m.content);
            let mut body = m.content.clone();
            for f in &m.files {
                body.push('\n');
                body.push_str(f);
            }
            if !m.reactions.is_empty() {
                let r: Vec<String> = m.reactions.iter().map(|(e, who)| format!("{e} {}", who.len())).collect();
                body.push_str(&format!("\n{}", r.join("  ")));
            }
            rows.push(MessageRow {
                id: m.id.to_hex(),
                own: m.author == me,
                author_pk: m.author.to_hex(),
                reply_to: None,
                initial: first_initial(&name),
                author: name,
                color: DEFAULT_ROLE,
                avatar,
                picture: if m.author == me { me_person.picture.clone() } else { person.picture.clone() },
                at: m.created_at,
                body: Some(body),
                reply: None,
                edited: m.edited,
                pinned: false,
                grouped,
                system: false,
                invite,
            });
        }
        Cx::post_action(Update::DmHeader { person, request });
        let mut mentions = Vec::new();
        for pk in [with, me] {
            let p = self.profile(&pk);
            for name in [p.name, p.display_name] {
                if is_word(&name) {
                    mentions.push((name.to_lowercase(), pk.to_hex()));
                }
            }
        }
        Cx::post_action(Update::Timeline { gid: "@dm".into(), channel_id: with.to_hex(), rows, can_pin: false, mentions });
    }

    /// Rails' Find People: a public key, or a name among people we know of
    /// (server members and DM peers). user@domain lookups need HTTP and
    /// aren't wired yet.
    async fn find_people(&self, q: &str) -> Vec<Person> {
        let q = q.trim();
        if q.is_empty() {
            return vec![];
        }
        if let Ok(pk) = PublicKey::parse(q) {
            self.session.want_profiles(&[pk]).await;
            return vec![self.person(&pk)];
        }
        let lower = q.to_lowercase();
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::new();
        let mut known: Vec<PublicKey> = self.session.conversations().unwrap_or_default().iter().map(|c| c.with).collect();
        for gid in self.session.servers().unwrap_or_default() {
            if let Ok(Some(state)) = self.session.server(&gid) {
                known.extend(state.members.keys().copied());
            }
        }
        for pk in known {
            if pk == self.session.keys().public_key() || !seen.insert(pk) {
                continue;
            }
            let p = self.person(&pk);
            if p.name.to_lowercase().contains(&lower) {
                out.push(p);
            }
        }
        out.truncate(25);
        out
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
            picture: s("picture"),
            banner: s("banner"),
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
                self.forget_previews(&gid);
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
            SessionUpdate::Profile(_) => self.refresh_people(),
            SessionUpdate::Dm(_) | SessionUpdate::Social => {
                // The badge and request bar show everywhere, not only in Home.
                self.publish_home();
                if self.dm.is_some() {
                    self.publish_dm();
                }
            }
        }
    }

    /// Someone's profile changed: everything that shows people.
    fn refresh_people(&mut self) {
        self.publish_me();
        self.refresh_all();
        self.publish_home();
        if self.dm.is_some() {
            self.publish_dm();
        }
    }

    /// The card for the first invite link in `body`, starting its lookup
    /// the first time the link is seen.
    fn invite_card(&mut self, body: &str) -> Option<(String, InviteCard)> {
        let link = crate::message_format::invite_link(body)?;
        if let Some(card) = self.previews.get(&link) {
            return Some((link, card.clone()));
        }
        self.previews.insert(link.clone(), InviteCard::Loading);
        let (session, tx, key) = (self.session.clone(), self.preview_tx.clone(), link.clone());
        tokio::spawn(async move {
            let card = match session.preview_invite(&key).await {
                Ok(p) => InviteCard::Ready(p),
                Err(_) => InviteCard::Unavailable,
            };
            let _ = tx.send((key, card));
        });
        Some((link, InviteCard::Loading))
    }

    /// Cards for `gid` are stale once its state changes (joined, revoked…).
    fn forget_previews(&mut self, gid: &str) {
        self.previews.retain(|_, c| !matches!(c, InviteCard::Ready(p) if p.gid == gid));
    }

    /// Redraws whichever conversation is open.
    fn republish_messages(&mut self) {
        if self.home {
            self.publish_dm();
        } else {
            self.publish_timeline();
        }
    }

    fn refresh_all(&mut self) {
        self.publish_servers();
        self.publish_server_keep_channel();
    }

    fn publish_gifs(&mut self) {
        if let Ok((favorites, collections)) = self.session.gif_library() {
            Cx::post_action(Update::GifLibrary { favorites, collections });
        }
    }

    fn publish_emoji_sets(&mut self) {
        let sets = self
            .session
            .servers()
            .unwrap_or_default()
            .iter()
            .filter_map(|gid| {
                let state = self.session.server(gid).ok().flatten()?;
                Some(crate::picker::ServerSet {
                    gid: gid.clone(),
                    name: state.metadata.name.clone(),
                    emojis: state.emojis.iter().map(|e| (e.name.clone(), e.url.clone())).collect(),
                    stickers: state.stickers.iter().map(|s| (s.name.clone(), s.url.clone())).collect(),
                })
            })
            .filter(|s| !s.emojis.is_empty() || !s.stickers.is_empty())
            .collect();
        Cx::post_action(Update::EmojiSets(sets));
    }

    fn publish_servers(&mut self) {
        self.publish_emoji_sets();
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
                let meta = self.session.server(gid).ok().flatten().map(|s| s.metadata);
                let name = meta.as_ref().map(|m| m.name.clone()).filter(|n| !n.is_empty()).unwrap_or_else(|| "…".into());
                let picture = meta.and_then(|m| m.picture);
                ServerItem { gid: gid.clone(), initials: initials(&name), name, picture }
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

    /// Rails' wizard for a server we haven't been through yet (on any
    /// device); never for its owner. Checked whenever the server's state
    /// comes in, since its settings may arrive after we open it.
    fn maybe_onboard(&mut self) {
        let Some(gid) = self.server.clone() else { return };
        if self.wizard_shown.contains(&gid) {
            return;
        }
        let me = self.session.keys().public_key();
        let due = self.session.server(&gid).ok().flatten().is_some_and(|s| s.metadata.onboarding && !s.is_owner(&me) && s.is_member(&me));
        if due && !self.session.onboarded(&gid) {
            self.wizard_shown.insert(gid.clone());
            if let Some(o) = self.onboarding(&gid, false) {
                Cx::post_action(Update::Onboarding(o));
            }
        }
    }

    /// The wizard's contents for `gid`.
    fn onboarding(&self, gid: &str, preview: bool) -> Option<Onboarding> {
        let state = self.session.server(gid).ok().flatten()?;
        let me = self.session.keys().public_key();
        let mine = state.members.get(&me).map(|m| m.roles.clone()).unwrap_or_default();
        let mut picks: Vec<_> = state
            .roles
            .iter()
            .filter(|r| r.self_assignable && !r.is_everyone() && r.permissions.get("administrator").and_then(|v| v.as_bool()) != Some(true))
            .collect();
        picks.sort_by_key(|r| std::cmp::Reverse(r.position));
        let roles = picks.into_iter().map(|r| (r.id.clone(), r.name.clone(), hex_color(&r.color).unwrap_or(0x99aab5), mine.contains(&r.id))).collect();
        let named: Vec<String> = state.metadata.highlights.iter().filter_map(|id| state.channel(id)).map(|c| c.name.clone()).collect();
        let channels = if named.is_empty() {
            let mut text: Vec<_> = state.structure.channels.iter().filter(|c| c.kind != "voice" && state.can_read(&me, c)).collect();
            text.sort_by_key(|c| c.position);
            text.into_iter().take(5).map(|c| c.name.clone()).collect()
        } else {
            named
        };
        let m = &state.metadata;
        Some(Onboarding {
            gid: gid.to_owned(),
            name: m.name.clone(),
            about: m.about.clone(),
            picture: m.picture.clone(),
            rules: m.rules.clone(),
            roles,
            channels,
            preview,
        })
    }

    fn publish_server_keep_channel(&mut self) {
        let people = People::new(&self.session);
        let Some(gid) = self.server.clone() else { return };
        let Ok(Some(state)) = self.session.server(&gid) else { return };

        // Rails' order: root channels and categories interleaved by
        // position, each category's channels under it. Channels we can't
        // read are hidden, as Rails does.
        let me = self.session.keys().public_key();
        let readable = |c: &inferno_core::server::wire::Channel| state.can_read(&me, c);
        // A channel and its embers (Rails' Hearth/Ember nesting).
        let push_tree = |sidebar: &mut Vec<SidebarRow>, id: &str| {
            for n in inferno_core::server::order::with_embers(&state.structure, id) {
                let Some(c) = state.channel(&n.id).filter(|c| readable(c)) else { continue };
                sidebar.push(SidebarRow::Channel {
                    id: c.id.clone(),
                    name: c.name.clone(),
                    voice: c.kind == "voice",
                    encrypted: c.encrypted,
                    category: c.category.clone(),
                    depth: n.depth as u8,
                    last: n.last,
                    guides: n.guides.clone(),
                });
            }
        };
        let mut sidebar = Vec::new();
        for item in inferno_core::server::order::root_items(&state.structure) {
            match item {
                inferno_core::server::order::RootItem::Channel(id) => push_tree(&mut sidebar, &id),
                inferno_core::server::order::RootItem::Category(id) => {
                    let name = state.structure.categories.iter().find(|c| c.id == id).map(|c| c.name.to_uppercase()).unwrap_or_default();
                    sidebar.push(SidebarRow::Category { id: id.clone(), name });
                    for cid in inferno_core::server::order::in_category(&state.structure, &id) {
                        push_tree(&mut sidebar, &cid);
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
            members.extend(list.iter().map(|m| member_row(&state, &m.pubkey, &me, &people)));
        };
        if let Some(owner) = state.owner.filter(|o| !state.members.contains_key(o)) {
            // The owner has no member event of their own when they made the server here.
            members.push(MemberRow::Header { text: "OWNER — 1".into(), color: 0x878583 });
            members.push(member_row(&state, &owner, &me, &people));
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
            manage_invites: state.has(&me, inferno_core::server::Permission::ManageInvites),
            create_emojis: state.has(&me, inferno_core::server::Permission::CreateEmojis),
            create_stickers: state.has(&me, inferno_core::server::Permission::CreateStickers),
            manage_emojis: state.has(&me, inferno_core::server::Permission::ManageEmojis),
            owner: state.is_owner(&me),
            send_custom_emojis: state.has(&me, inferno_core::server::Permission::SendCustomEmojis),
            send_custom_stickers: state.has(&me, inferno_core::server::Permission::SendCustomStickers),
            send_gifs: state.has(&me, inferno_core::server::Permission::SendGifs),
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
                hearth: state.structure.hearth_of(&c.id).map(str::to_owned),
                voice_bitrate: c.voice_bitrate,
                voice_user_limit: c.voice_user_limit,
                video_enabled: c.video_enabled,
                depth: state.structure.ancestors(&c.id).len() as u8,
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
                perms: {
                    let mut on: Vec<String> =
                        r.permissions.iter().filter(|(_, v)| v.as_bool() == Some(true)).map(|(k, _)| k.clone()).collect();
                    for k in DEFAULT_ON {
                        if r.permissions.get(k).and_then(|v| v.as_bool()) != Some(false) && !on.iter().any(|o| o == k) {
                            on.push(k.to_owned());
                        }
                    }
                    on
                },
                everyone: r.is_everyone(),
                role_type: r.role_type.clone(),
                self_assignable: r.self_assignable,
                raw_perms: r.permissions.clone(),
                member_count: if r.is_everyone() {
                    state.members.len() + usize::from(state.owner.is_some_and(|o| !state.members.contains_key(&o)))
                } else {
                    state.members.values().filter(|m| m.roles.contains(&r.id)).count()
                },
            })
            .collect();
        role_forms.sort_by_key(|r| std::cmp::Reverse(r.position));
        let bans = state
            .bans
            .iter()
            .map(|(pk, b)| BanItem { pubkey: pk.to_hex(), name: display(&state, pk, &people).name, reason: b.reason.clone() })
            .collect();
        let mut invites: Vec<InviteItem> = state
            .invites
            .values()
            .filter_map(|i| {
                Some(InviteItem {
                    code: i.code.clone(),
                    link: self.session.invite_link(&gid, &i.code)?,
                    by: display(&state, &i.created_by, &people).name,
                    created_at: i.created_at,
                    uses: state.invite_uses(&i.code),
                    max_uses: i.max_uses,
                    expires_at: i.expires_at,
                    can_revoke: state.may_revoke(&me, i),
                })
            })
            .collect();
        invites.sort_by_key(|i| std::cmp::Reverse(i.created_at));
        let mut text: Vec<_> = state.structure.channels.iter().filter(|c| c.kind != "voice").collect();
        text.sort_by_key(|c| c.position);
        let text_channels = text.into_iter().map(|c| RoleItem { id: c.id.clone(), name: c.name.clone() }).collect();
        let now = inferno_core::store::now_secs();
        let mut sorted_roles: Vec<_> = state.roles.iter().filter(|r| !r.is_everyone()).collect();
        sorted_roles.sort_by_key(|r| std::cmp::Reverse(r.position));
        let mut pks: Vec<PublicKey> = state.members.keys().copied().collect();
        if let Some(o) = state.owner.filter(|o| !state.members.contains_key(o)) {
            pks.push(o);
        }
        let mut member_infos: Vec<MemberInfo> = pks
            .iter()
            .map(|pk| {
                let d = display(&state, pk, &people);
                let m = state.members.get(pk);
                let held = m.map(|m| m.roles.clone()).unwrap_or_default();
                MemberInfo {
                    pubkey: pk.to_hex(),
                    initial: first_initial(&d.name),
                    name: d.name,
                    avatar: d.avatar,
                    picture: d.picture,
                    roles: sorted_roles
                        .iter()
                        .filter(|r| held.contains(&r.id))
                        .map(|r| (r.name.clone(), hex_color(&r.color).unwrap_or(0x99aab5)))
                        .collect(),
                    role_ids: held,
                    joined_at: m.and_then(|m| m.joined_at),
                    timed_out_until: state.timed_out_until(pk, now),
                    owner: state.is_owner(pk),
                    me: *pk == me,
                }
            })
            .collect();
        member_infos.sort_by(|a, b| b.owner.cmp(&a.owner).then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase())));
        let m = &state.metadata;
        let by = |pk: &Option<PublicKey>| pk.map(|p| display(&state, &p, &people).name).unwrap_or_default();
        let emojis = state.emojis.iter().map(|e| CustomItem { name: e.name.clone(), description: String::new(), url: e.url.clone(), by: by(&e.creator) }).collect();
        let stickers = state
            .stickers
            .iter()
            .map(|s| CustomItem { name: s.name.clone(), description: s.description.clone(), url: s.url.clone(), by: by(&s.creator) })
            .collect();
        let audit = self
            .session
            .audit_log(&gid)
            .unwrap_or_default()
            .into_iter()
            .take(200)
            .map(|e| {
                use inferno_core::server::audit::Action as A;
                let name = |pk: &PublicKey| display(&state, pk, &people).name;
                let (text, tone) = match &e.action {
                    A::Settings => ("updated server settings".to_owned(), 0),
                    A::Channels => ("updated channels".into(), 0),
                    A::Roles => ("updated roles".into(), 1),
                    A::Emojis => ("updated emojis".into(), 3),
                    A::Stickers => ("updated stickers".into(), 3),
                    A::Joined => ("joined the server".into(), 2),
                    A::Left => ("left the server".into(), 2),
                    A::Kicked(t) => (format!("kicked {}", name(t)), 4),
                    A::TimedOut { target, secs } => {
                        (format!("timed out {} for {}", name(target), crate::time_fmt::in_words(*secs).trim_start_matches("about ")), 3)
                    }
                    A::TimeoutLifted(t) => (format!("removed {}'s timeout", name(t)), 2),
                    A::RolesChanged(t) => (format!("changed {}'s roles", name(t)), 1),
                    A::Banned { target, reason } if reason.is_empty() => (format!("banned {}", name(target)), 4),
                    A::Banned { target, reason } => (format!("banned {} — {reason}", name(target)), 4),
                    A::Unbanned(t) => (format!("unbanned {}", name(t)), 2),
                    A::InviteCreated => ("created an invite".into(), 5),
                    A::InviteRevoked => ("revoked an invite".into(), 5),
                };
                AuditItem { actor: name(&e.actor), text, at: e.at, tone }
            })
            .collect();
        let mut voice_channels = Vec::new();
        for item in inferno_core::server::order::root_items(&state.structure) {
            let ids = match item {
                inferno_core::server::order::RootItem::Channel(id) => vec![id],
                inferno_core::server::order::RootItem::Category(id) => inferno_core::server::order::in_category(&state.structure, &id),
            };
            for id in ids {
                for n in inferno_core::server::order::with_embers(&state.structure, &id) {
                    let Some(c) = state.channel(&n.id).filter(|c| c.kind == "voice") else { continue };
                    let limit = if c.voice_user_limit == 0 { "no user limit".to_owned() } else { format!("up to {} people", c.voice_user_limit) };
                    let video = if c.video_enabled { " · video on" } else { "" };
                    let nested = state.structure.hearth_of(&c.id).and_then(|h| state.channel(h)).map(|h| format!(" · ember of {}", h.name)).unwrap_or_default();
                    let summary = format!("{} kbps · {limit}{video}{nested}", c.voice_bitrate / 1000);
                    voice_channels.push((c.id.clone(), format!("{}{}", "\u{a0}\u{a0}".repeat(n.depth), c.name), summary));
                }
            }
        }
        Cx::post_action(Update::ServerSettings(ServerSettings {
            onboarding: m.onboarding,
            rules: m.rules.clone(),
            highlights: m.highlights.clone(),
            server_relays: m.relays.clone(),
            global_relays: self.session.relays().unwrap_or_default().into_iter().map(|r| r.url).collect(),
            voice_enabled: m.voice_enabled,
            voice_providers: m.voice_providers.iter().map(|pk| display(&state, pk, &people).name).collect(),
            me_provider: m.voice_providers.contains(&me),
            afk_channel: m.afk_channel.clone(),
            afk_timeout: m.afk_timeout_mins,
            afk_action: m.afk_action.clone(),
            voice_channels,
            audit,
            emojis,
            stickers,
            members: member_infos,
            name: m.name.clone(),
            about: m.about.clone(),
            picture: m.picture.clone().unwrap_or_default(),
            banner: m.banner.clone().unwrap_or_default(),
            server_type: m.server_type.clone(),
            welcome_channel: m.welcome_channel.clone(),
            text_channels,
            // The owner of a new server has no member event yet.
            my_rank: if state.is_owner(&me) {
                i64::MAX
            } else {
                let held = state.members.get(&me).map(|m| m.roles.clone()).unwrap_or_default();
                let admin = state.has(&me, inferno_core::server::Permission::Administrator);
                // Administrators rank just under the owner (Flutter).
                if admin { i64::MAX - 1 } else { state.roles.iter().filter(|r| held.contains(&r.id)).map(|r| r.position).max().unwrap_or(0) }
            },
            member_count: state.members.len() + usize::from(state.owner.is_some_and(|o| !state.members.contains_key(&o))),
            invites,
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
        self.maybe_onboard();
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
        let mut invites: Vec<_> = timeline.iter().map(|m| m.content.as_deref().and_then(|c| self.invite_card(c))).collect();
        let people = People::new(&self.session);
        let by_id: HashMap<EventId, usize> = timeline.iter().enumerate().map(|(i, m)| (m.id, i)).collect();
        let mut rows = Vec::with_capacity(timeline.len());
        for (i, m) in timeline.iter().enumerate() {
            let d = display(&state, &m.author, &people);
            let invite = invites[i].take();
            let prev = i.checked_sub(1).map(|p| &timeline[p]);
            let grouped = prev.is_some_and(|p| p.author == m.author && m.reply_to.is_none() && m.created_at - p.created_at < 300);
            let reply = m.reply_to.and_then(|id| by_id.get(&id)).map(|&pi| {
                let p = &timeline[pi];
                let cut: String = p.content.as_deref().unwrap_or("…").chars().take(60).collect();
                format!("↳ {}  {}", display(&state, &p.author, &people).name, cut)
            });
            rows.push(MessageRow {
                id: m.id.to_hex(),
                own: m.author == self.session.keys().public_key(),
                author_pk: m.author.to_hex(),
                reply_to: m.reply_to.map(|r| r.to_hex()),
                initial: first_initial(&d.name),
                author: d.name,
                color: d.color,
                avatar: d.avatar,
                picture: d.picture,
                at: m.created_at,
                body: m.content.clone(),
                reply,
                edited: m.edited_at.is_some(),
                pinned: m.pinned,
                grouped,
                system: false,
                invite,
            });
        }
        let can_pin = state.has(&self.session.keys().public_key(), inferno_core::server::Permission::ManageMessages);
        let mentions = server_mentions(&state, &people);
        Cx::post_action(Update::Timeline { gid, channel_id: ch, rows, can_pin, mentions });
    }
}
