//! Parsers for the server-state kinds, matching what Rails publishes
//! (`app/jobs/nostr_server_publish_job.rb`) tag for tag. All state lives in
//! tags; content is unused. Positional tags (`ch`, `role`, `cat`) are read by
//! index exactly as Rails writes them; missing trailing fields fall back to
//! Rails' defaults so older publishers still parse.

use nostr::prelude::*;
use serde_json::{Map, Value};

fn tag<'a>(event: &'a Event, name: &str) -> Option<&'a str> {
    event.tags.iter().find_map(|t| {
        let s = t.as_slice();
        (s.first().map(String::as_str) == Some(name)).then(|| s.get(1).map(String::as_str)).flatten()
    })
}

fn rows<'a>(event: &'a Event, name: &'a str) -> impl Iterator<Item = &'a [String]> + 'a {
    event
        .tags
        .iter()
        .map(|t| t.as_slice())
        .filter(move |s| s.first().map(String::as_str) == Some(name))
}

fn flag(v: Option<&str>) -> bool {
    v == Some("true")
}

fn text(v: Option<&String>) -> String {
    v.cloned().unwrap_or_default()
}

fn opt(v: Option<&String>) -> Option<String> {
    v.filter(|s| !s.is_empty()).cloned()
}

fn num<T: std::str::FromStr>(v: Option<&String>, default: T) -> T {
    v.and_then(|s| s.parse().ok()).unwrap_or(default)
}

fn json_map(v: Option<&String>) -> Map<String, Value> {
    match v.map(|s| serde_json::from_str(s)) {
        Some(Ok(Value::Object(m))) => m,
        _ => Map::new(),
    }
}

/// The server a state event belongs to: the `server` tag, or for metadata
/// (which has none) its d-tag minus `inferno-`.
pub fn server_gid(event: &Event) -> Option<String> {
    if let Some(gid) = tag(event, "server") {
        return Some(gid.to_owned());
    }
    let d = event.tags.identifier()?;
    crate::dtag::gid_from(event.kind.as_u16(), &d).map(str::to_owned)
}

/// The member/ban target, from the `p` tag.
pub fn target(event: &Event) -> Option<PublicKey> {
    event.tags.public_keys().next()
}

// ─── 31750 metadata ──────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Metadata {
    pub name: String,
    pub about: String,
    pub owner: Option<PublicKey>,
    pub picture: Option<String>,
    pub banner: Option<String>,
    pub relays: Vec<String>,
    pub welcome_channel: Option<String>,
    pub welcome_message: String,
    pub welcome_enabled: bool,
    pub voice_enabled: bool,
    pub discoverable: bool,
    pub server_type: String,
    pub age_restricted: bool,
    pub afk_channel: Option<String>,
    pub afk_timeout_mins: u32,
    pub afk_action: String,
    pub voice_providers: Vec<PublicKey>,
    /// Rails marks a deleted server with a `deleted` tag on its metadata.
    pub deleted: bool,
    /// Onboarding (ours; Rails kept it off Nostr): show new members the
    /// wizard, with these rules (in order) and highlighted channels.
    pub onboarding: bool,
    pub rules: Vec<String>,
    pub highlights: Vec<String>,
}

pub fn metadata(event: &Event) -> Metadata {
    let one = |n| tag(event, n).map(str::to_owned);
    Metadata {
        name: one("name").unwrap_or_default(),
        about: one("about").unwrap_or_default(),
        owner: tag(event, "owner").and_then(|p| PublicKey::from_hex(p).ok()),
        picture: one("picture").filter(|s| !s.is_empty()),
        banner: one("banner").filter(|s| !s.is_empty()),
        relays: rows(event, "relay").filter_map(|r| r.get(1).cloned()).collect(),
        welcome_channel: one("welcome_channel").filter(|s| !s.is_empty()),
        welcome_message: one("welcome_message").unwrap_or_default(),
        welcome_enabled: flag(tag(event, "welcome_enabled")),
        voice_enabled: flag(tag(event, "voice_enabled")),
        discoverable: flag(tag(event, "discoverable")),
        server_type: one("server_type").unwrap_or_else(|| "community".into()),
        age_restricted: flag(tag(event, "age_restricted")),
        afk_channel: one("afk_channel").filter(|s| !s.is_empty()),
        afk_timeout_mins: tag(event, "afk_timeout").and_then(|s| s.parse().ok()).unwrap_or(5),
        afk_action: one("afk_action").unwrap_or_else(|| "move".into()),
        voice_providers: rows(event, "voice_provider")
            .filter_map(|r| PublicKey::from_hex(r.get(1)?).ok())
            .collect(),
        deleted: flag(tag(event, "deleted")),
        onboarding: flag(tag(event, "onboarding")),
        rules: rows(event, "rule").filter_map(|r| r.get(1).cloned()).filter(|r| !r.trim().is_empty()).collect(),
        highlights: rows(event, "highlight_channel").filter_map(|r| r.get(1).cloned()).collect(),
    }
}

// ─── 31751 structure ─────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub struct Category {
    pub id: String,
    pub name: String,
    pub position: i64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Channel {
    pub id: String,
    pub name: String,
    /// `text`, `voice`, ... as Rails names them.
    pub kind: String,
    pub position: i64,
    pub category: Option<String>,
    pub topic: String,
    pub nsfw: bool,
    /// The `h` tag messages in this channel carry.
    pub group_id: Option<String>,
    pub permission_overrides: Map<String, Value>,
    pub encrypted: bool,
    /// Public half of the channel key, for encrypted channels.
    pub channel_pubkey: Option<String>,
    pub sidechat: Option<String>,
    pub parent: Option<String>,
    pub voice_bitrate: u32,
    pub voice_user_limit: u32,
    pub video_enabled: bool,
    pub post_only: bool,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Structure {
    pub categories: Vec<Category>,
    pub channels: Vec<Channel>,
}

impl Structure {
    /// Rails' nesting depth: a channel plus up to two hearths above it.
    pub const MAX_NESTING: usize = 3;

    /// The hearth `id` is drawn under, if its `parent` is usable: a voice
    /// channel here, not itself, no loop, within Rails' three levels.
    /// Anything else (a deleted or text parent from another client) puts it
    /// back at the top of its category.
    pub fn hearth_of(&self, id: &str) -> Option<&str> {
        let c = self.channels.iter().find(|c| c.id == id)?;
        let parent = c.parent.as_deref()?;
        self.check_hearth(id, parent).ok().map(|_| parent)
    }

    /// The hearths above `id`, nearest first (stops at a broken link).
    pub fn ancestors(&self, id: &str) -> Vec<String> {
        let mut out = Vec::new();
        let mut cur = id.to_owned();
        while let Some(p) = self.channels.iter().find(|c| c.id == cur).and_then(|c| c.parent.clone()) {
            if p == id || out.contains(&p) || out.len() > Self::MAX_NESTING {
                break;
            }
            out.push(p.clone());
            cur = p;
        }
        out
    }

    /// Whether `parent` can be `id`'s hearth (Rails' `parent_channel_valid`).
    pub fn check_hearth(&self, id: &str, parent: &str) -> Result<(), &'static str> {
        let p = self.channels.iter().find(|c| c.id == parent).ok_or("that hearth doesn't exist")?;
        if p.kind != "voice" {
            return Err("a hearth must be a voice channel");
        }
        if parent == id {
            return Err("a channel can't be its own hearth");
        }
        let above = self.ancestors(parent);
        if above.iter().any(|a| a == id) {
            return Err("that would make a loop");
        }
        // The hearth's own chain must itself be sound.
        if above.iter().any(|a| self.channels.iter().find(|c| &c.id == a).is_none_or(|c| c.kind != "voice")) {
            return Err("that hearth isn't nested properly");
        }
        // Depth of the hearth's subtree under `id` counts too, when moving.
        let depth_below = self.depth_below(id);
        if above.len() + 1 + depth_below + 1 > Self::MAX_NESTING {
            return Err("channels nest at most three levels deep");
        }
        Ok(())
    }

    /// How many levels of embers sit under `id`.
    fn depth_below(&self, id: &str) -> usize {
        fn go(s: &Structure, id: &str, seen: &mut Vec<String>) -> usize {
            if seen.iter().any(|x| x == id) || seen.len() > Structure::MAX_NESTING {
                return 0;
            }
            seen.push(id.to_owned());
            let d = s.channels.iter().filter(|c| c.parent.as_deref() == Some(id)).map(|c| 1 + go(s, &c.id, seen)).max().unwrap_or(0);
            seen.pop();
            d
        }
        go(self, id, &mut Vec::new())
    }

    pub fn channel_is_root(&self, id: &str) -> bool {
        self.channels.iter().any(|c| c.id == id && c.category.is_none())
    }
}

pub fn structure(event: &Event) -> Structure {
    let categories = rows(event, "cat")
        .filter_map(|t| {
            Some(Category { id: t.get(1)?.clone(), name: text(t.get(2)), position: num(t.get(3), 0) })
        })
        .collect();
    let channels = rows(event, "ch")
        .filter_map(|t| {
            Some(Channel {
                id: t.get(1)?.clone(),
                name: text(t.get(2)),
                kind: opt(t.get(3)).unwrap_or_else(|| "text".into()),
                position: num(t.get(4), 0),
                category: opt(t.get(5)),
                topic: text(t.get(6)),
                nsfw: flag(t.get(7).map(String::as_str)),
                group_id: opt(t.get(8)),
                permission_overrides: json_map(t.get(9)),
                encrypted: flag(t.get(10).map(String::as_str)),
                channel_pubkey: opt(t.get(11)),
                sidechat: opt(t.get(12)),
                parent: opt(t.get(13)),
                voice_bitrate: num(t.get(14), 64_000),
                voice_user_limit: num(t.get(15), 0),
                video_enabled: flag(t.get(16).map(String::as_str)),
                post_only: flag(t.get(17).map(String::as_str)),
            })
        })
        .collect();
    Structure { categories, channels }
}

// ─── 31752 roles ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub struct Role {
    pub id: String,
    pub name: String,
    pub color: String,
    pub position: i64,
    pub hoist: bool,
    pub mentionable: bool,
    pub permissions: Map<String, Value>,
    pub role_type: String,
    /// Members may pick it themselves during onboarding. Ours: a tenth
    /// element on the role tag, which Rails and Flutter don't read.
    pub self_assignable: bool,
}

impl Role {
    pub fn is_everyone(&self) -> bool {
        self.name == "@everyone"
    }
}

pub fn roles(event: &Event) -> Vec<Role> {
    rows(event, "role")
        .filter_map(|t| {
            Some(Role {
                id: t.get(1)?.clone(),
                name: text(t.get(2)),
                color: opt(t.get(3)).unwrap_or_else(|| "#99aab5".into()),
                position: num(t.get(4), 0),
                hoist: flag(t.get(5).map(String::as_str)),
                mentionable: flag(t.get(6).map(String::as_str)),
                permissions: json_map(t.get(7)),
                role_type: text(t.get(8)),
                self_assignable: flag(t.get(9).map(String::as_str)),
            })
        })
        .collect()
}

// ─── 31753 member ────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Default)]
pub struct MemberProfile {
    pub name: String,
    pub display_name: String,
    pub about: String,
    pub picture: Option<String>,
    pub banner: Option<String>,
    pub color: Option<String>,
    pub color_2: Option<String>,
    pub status: String,
    pub status_emoji: String,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct MemberEvent {
    pub removed: bool,
    /// `None` when the event carries no `roles` tag at all (leave the roles
    /// as they were); `Some(empty)` means all roles were taken away.
    pub roles: Option<Vec<String>>,
    pub nickname: Option<String>,
    pub joined_at: Option<i64>,
    pub timed_out_until: Option<i64>,
    pub timed_out_by: Option<PublicKey>,
    /// The invite code the member joined with (their own events only).
    pub invite: Option<String>,
    /// Whether the event carries a profile at all (moderators' don't).
    pub has_profile: bool,
    /// Roles the member picked themselves (ours; only self-assignable
    /// roles count, see `ServerState`).
    pub self_roles: Option<Vec<String>>,
    pub profile: MemberProfile,
}

pub fn member(event: &Event) -> MemberEvent {
    let one = |n| tag(event, n).map(str::to_owned);
    let nonempty = |n| one(n).filter(|s| !s.is_empty());
    MemberEvent {
        removed: flag(tag(event, "removed")),
        roles: rows(event, "roles").next().map(|r| r[1..].to_vec()),
        nickname: one("nickname"),
        joined_at: tag(event, "joined_at").and_then(|s| s.parse().ok()),
        timed_out_until: tag(event, "timed_out_until").and_then(|s| s.parse().ok()),
        timed_out_by: tag(event, "timed_out_by").and_then(|p| PublicKey::from_hex(p).ok()),
        invite: nonempty("invite"),
        has_profile: tag(event, "profile_name").is_some() || tag(event, "profile_display_name").is_some(),
        self_roles: rows(event, "self_roles").next().map(|r| r[1..].to_vec()),
        profile: MemberProfile {
            name: one("profile_name").unwrap_or_default(),
            display_name: one("profile_display_name").unwrap_or_default(),
            about: one("profile_about").unwrap_or_default(),
            picture: nonempty("profile_picture"),
            banner: nonempty("profile_banner"),
            color: nonempty("profile_color"),
            color_2: nonempty("profile_color_2"),
            status: one("profile_status").unwrap_or_default(),
            status_emoji: one("profile_status_emoji").unwrap_or_default(),
        },
    }
}

// ─── 31754 / 31755 emoji and stickers ────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub struct Emoji {
    pub name: String,
    pub url: String,
    pub creator: Option<PublicKey>,
}

pub fn emojis(event: &Event) -> Vec<Emoji> {
    rows(event, "emoji")
        .filter_map(|t| {
            Some(Emoji {
                name: t.get(1)?.clone(),
                url: t.get(2)?.clone(),
                creator: t.get(3).and_then(|p| PublicKey::from_hex(p).ok()),
            })
        })
        .collect()
}

#[derive(Debug, Clone, PartialEq)]
pub struct Sticker {
    pub name: String,
    pub description: String,
    pub url: String,
    pub creator: Option<PublicKey>,
}

pub fn stickers(event: &Event) -> Vec<Sticker> {
    rows(event, "sticker")
        .filter_map(|t| {
            Some(Sticker {
                name: t.get(1)?.clone(),
                description: text(t.get(2)),
                url: t.get(3)?.clone(),
                creator: t.get(4).and_then(|p| PublicKey::from_hex(p).ok()),
            })
        })
        .collect()
}

// ─── 31756 ban ───────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Default)]
pub struct BanEvent {
    pub unbanned: bool,
    pub reason: String,
    pub banned_by: Option<PublicKey>,
}

pub fn ban(event: &Event) -> BanEvent {
    BanEvent {
        unbanned: flag(tag(event, "unbanned")),
        reason: tag(event, "reason").unwrap_or_default().to_owned(),
        banned_by: tag(event, "banned_by").and_then(|p| PublicKey::from_hex(p).ok()),
    }
}

// ─── 31757 invite ────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Default)]
pub struct InviteEvent {
    pub code: String,
    pub revoked: bool,
    /// 0 = unlimited.
    pub max_uses: u32,
    /// Unix seconds; 0 = never.
    pub expires_at: i64,
    pub created_by: Option<PublicKey>,
}

pub fn invite(event: &Event) -> InviteEvent {
    InviteEvent {
        code: tag(event, "code").unwrap_or_default().to_owned(),
        revoked: flag(tag(event, "revoked")),
        max_uses: tag(event, "max_uses").and_then(|s| s.parse().ok()).unwrap_or(0),
        expires_at: tag(event, "expires_at").and_then(|s| s.parse().ok()).unwrap_or(0),
        created_by: tag(event, "created_by").and_then(|p| PublicKey::from_hex(p).ok()),
    }
}
