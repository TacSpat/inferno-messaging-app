//! Who is in which voice channel.
//!
//! Each person has one voice state (kind 10070 is replaceable), tagged with
//! the server it's in, in Flutter's format: `{"type":"voice_state_sync",
//! "action":"join"|"update"|"leave", "channel_id", ...}`. Flutter published
//! a join with a two-hour expiry and never again, so a crash left people
//! "in" a channel for hours; here a state expires after `EXPIRY` and is
//! re-published every `REFRESH` while we stay, and states past their expiry
//! (or older than one we already have) are ignored.

use std::collections::HashMap;

use nostr_sdk::prelude::*;
use serde_json::{json, Value};

use super::{Result, Session, SessionError, Update};
use crate::kinds;
use crate::livekit_token::{self, Credentials, Grant};
use nostr::nips::nip44;

/// How long a published state holds without a refresh.
const EXPIRY: u64 = 5 * 60;
/// How often a state is re-published while we stay in the channel.
const REFRESH: std::time::Duration = std::time::Duration::from_secs(2 * 60);
/// How often expired states are swept from the list.
const SWEEP: std::time::Duration = std::time::Duration::from_secs(20);

/// Someone in a voice channel.
#[derive(Debug, Clone, PartialEq)]
pub struct VoiceState {
    pub pubkey: PublicKey,
    pub gid: String,
    pub channel_id: String,
    pub self_mute: bool,
    pub self_deaf: bool,
    /// Muted or deafened by a moderator (Rails' server mute/deafen).
    pub server_mute: bool,
    pub server_deaf: bool,
    /// Heard in the embers below (Rails' hearth Broadcast).
    pub broadcasting: bool,
    /// From an ember, heard in the hearths above (let up after asking).
    pub showcased: bool,
    /// When they joined this channel (or when we first saw them in it).
    pub since: i64,
}

/// What a moderator does to someone in voice (Rails' voice context menu).
#[derive(Debug, Clone, PartialEq)]
pub enum VoiceModeration {
    ServerMute(bool),
    ServerDeafen(bool),
    /// To another voice channel of the same server.
    Move(String),
    Disconnect,
}

#[derive(Default)]
pub(super) struct Voice {
    /// Ours, as last published from this device.
    mine: Option<VoiceState>,
    /// When we last published, so our own echoes can be told apart.
    published_at: Option<Timestamp>,
    /// Everyone else (and us on other devices): their newest state's time,
    /// the state (`None` once they left) and when it expires.
    others: HashMap<PublicKey, (Timestamp, Option<VoiceState>, u64)>,
    /// Token requests waiting for a provider's answer, by request id.
    pending: HashMap<String, tokio::sync::oneshot::Sender<(String, String)>>,
}

/// Rails' wait for a provider's answer (Flutter waited 15s).
const RPC_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);
/// How old a voice request may be and still be acted on (a little over
/// the asker's wait, for clock differences).
const RPC_MAX_AGE_SECS: u64 = 30;
const CREDENTIALS_KEY: &str = "voice:livekit";

/// Where to connect: the LiveKit server and an access token for the room.
#[derive(Debug, Clone, PartialEq)]
pub struct VoiceTicket {
    pub url: String,
    pub token: String,
    pub room: String,
}

impl Voice {
    fn live(&self, now: u64) -> impl Iterator<Item = &VoiceState> {
        self.others.values().filter(move |(_, _, exp)| *exp > now).filter_map(|(_, s, _)| s.as_ref())
    }
}

/// This device, so our own states from other devices still show.
fn device_id(session: &Session) -> String {
    const KEY: &str = "voice:device_id";
    if let Ok(Some(id)) = session.store.get_setting::<String>(KEY) {
        return id;
    }
    let id: String = (0..8).map(|_| format!("{:02x}", rand::random::<u8>())).collect();
    let _ = session.store.set_setting(KEY, &id);
    id
}

fn tag<'a>(event: &'a Event, name: &str) -> Option<&'a str> {
    event.tags.iter().find_map(|t| {
        let s = t.as_slice();
        (s.first().map(String::as_str) == Some(name)).then(|| s.get(1).map(String::as_str)).flatten()
    })
}

/// What an event says, if it's a voice state at all: (action, gid, channel,
/// mute, deaf, device, expiry).
struct Parsed {
    action: String,
    gid: String,
    channel_id: String,
    self_mute: bool,
    self_deaf: bool,
    server_mute: bool,
    server_deaf: bool,
    broadcasting: bool,
    showcased: bool,
    device_id: String,
    expires: u64,
}

fn parse(event: &Event) -> Option<Parsed> {
    let v: Value = serde_json::from_str(&event.content).ok()?;
    if v.get("type")?.as_str()? != "voice_state_sync" {
        return None;
    }
    let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    let gid = Some(s("server_nostr_group_id")).filter(|g| !g.is_empty()).or_else(|| tag(event, "h").map(str::to_owned))?;
    // Flutter's two hours when there's no expiry tag at all.
    let expires = tag(event, "expiration").and_then(|e| e.parse().ok()).unwrap_or(event.created_at.as_secs() + 2 * 3600);
    Some(Parsed {
        action: s("action"),
        gid,
        channel_id: s("channel_id"),
        self_mute: v.get("self_mute").and_then(Value::as_bool).unwrap_or(false),
        self_deaf: v.get("self_deaf").and_then(Value::as_bool).unwrap_or(false),
        server_mute: v.get("server_mute").and_then(Value::as_bool).unwrap_or(false),
        server_deaf: v.get("server_deaf").and_then(Value::as_bool).unwrap_or(false),
        broadcasting: v.get("broadcasting").and_then(Value::as_bool).unwrap_or(false),
        showcased: v.get("showcased").and_then(Value::as_bool).unwrap_or(false),
        device_id: s("device_id"),
        expires,
    })
}

impl Session {
    /// Everyone in a voice channel of `gid`, us included, earliest first.
    pub fn voice_states(&self, gid: &str) -> Vec<VoiceState> {
        let now = Timestamp::now().as_secs();
        let voice = self.voice.lock().unwrap_or_else(|e| e.into_inner());
        let mut all: Vec<VoiceState> = voice.mine.iter().chain(voice.live(now)).filter(|s| s.gid == gid).cloned().collect();
        // Us on another device too: this device's state wins.
        let me = self.keys.public_key();
        if voice.mine.is_some() {
            let mut seen = false;
            all.retain(|s| s.pubkey != me || !std::mem::replace(&mut seen, true));
        }
        all.sort_by_key(|s| s.since);
        all
    }

    /// The voice channel this device is in.
    pub fn my_voice(&self) -> Option<VoiceState> {
        self.voice.lock().unwrap_or_else(|e| e.into_inner()).mine.clone()
    }

    /// Joins a voice channel (leaving the one we're in, which the same
    /// replaceable event does by itself).
    pub async fn join_voice(&self, gid: &str, channel_id: &str) -> Result<()> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        if !state.structure.channels.iter().any(|c| c.id == channel_id && c.kind == "voice") {
            return Err(SessionError::Unknown);
        }
        let previous = self.my_voice();
        let (mute, deaf) = previous.as_ref().map_or((false, false), |m| (m.self_mute, m.self_deaf));
        // A move within the server keeps a moderator's mute and deafen.
        let (server_mute, server_deaf) = previous.filter(|m| m.gid == gid).map_or((false, false), |m| (m.server_mute, m.server_deaf));
        // Rails: the AFK channel is joined muted.
        let mute = mute || state.metadata.afk_channel.as_deref() == Some(channel_id);
        let mine = VoiceState {
            pubkey: self.keys.public_key(),
            gid: gid.to_owned(),
            channel_id: channel_id.to_owned(),
            self_mute: mute,
            self_deaf: deaf,
            server_mute,
            server_deaf,
            broadcasting: false,
            showcased: false,
            since: Timestamp::now().as_secs() as i64,
        };
        let previous = self.voice.lock().unwrap_or_else(|e| e.into_inner()).mine.replace(mine.clone());
        if let Some(p) = previous.filter(|p| p.gid != gid) {
            let _ = self.updates.send(Update::Voice(p.gid));
        }
        let _ = self.updates.send(Update::Voice(gid.to_owned()));
        self.publish_voice("join", &mine, true).await
    }

    pub async fn leave_voice(&self) -> Result<()> {
        let Some(mine) = self.voice.lock().unwrap_or_else(|e| e.into_inner()).mine.take() else { return Ok(()) };
        let _ = self.updates.send(Update::Voice(mine.gid.clone()));
        self.publish_voice("leave", &mine, true).await
    }

    /// Rails' hearth Broadcast: whether the embers below hear us.
    pub async fn set_voice_broadcast(&self, on: bool) -> Result<()> {
        let mine = {
            let mut voice = self.voice.lock().unwrap_or_else(|e| e.into_inner());
            let Some(m) = voice.mine.as_mut() else { return Ok(()) };
            if m.broadcasting == on {
                return Ok(());
            }
            m.broadcasting = on;
            m.clone()
        };
        let _ = self.updates.send(Update::Voice(mine.gid.clone()));
        self.publish_voice("update", &mine, true).await
    }

    /// Lets `target`, in an ember below our channel, be heard here (or
    /// stops it). Needs `elevate_voice`, on by default.
    pub async fn showcase(&self, gid: &str, target: &PublicKey, on: bool) -> Result<()> {
        use crate::server::Permission;
        let mine = self.my_voice().filter(|m| m.gid == gid).ok_or(SessionError::Other("Join a voice channel above theirs first.".into()))?;
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let theirs = self.voice_states(gid).into_iter().find(|v| v.pubkey == *target).ok_or(SessionError::Other("They're not in voice.".into()))?;
        if !state.structure.ancestors(&theirs.channel_id).contains(&mine.channel_id) {
            return Err(SessionError::Other("They're not in a channel below yours.".into()));
        }
        if !state.has(&self.keys.public_key(), Permission::ElevateVoice) {
            return Err(SessionError::Other("You don't have permission to let others speak here.".into()));
        }
        let body = json!({"type": "voice_showcase", "on": on, "server_nostr_group_id": gid, "channel_id": theirs.channel_id});
        self.send_rpc(target, &body).await
    }

    /// Stops being heard in the hearths above (our own choice).
    pub async fn stop_showcase(&self) -> Result<()> {
        self.set_showcased(false).await
    }

    async fn set_showcased(&self, on: bool) -> Result<()> {
        let mine = {
            let mut voice = self.voice.lock().unwrap_or_else(|e| e.into_inner());
            let Some(m) = voice.mine.as_mut() else { return Ok(()) };
            if m.showcased == on {
                return Ok(());
            }
            m.showcased = on;
            m.clone()
        };
        let _ = self.updates.send(Update::Voice(mine.gid.clone()));
        self.publish_voice("update", &mine, true).await
    }

    /// Rails' "Ask to Speak": from an ember, asks the people in the hearths
    /// above to be heard.
    pub async fn ask_to_speak(&self) -> Result<()> {
        let mine = self.my_voice().ok_or(SessionError::Other("You're not in voice.".into()))?;
        let state = self.server(&mine.gid)?.ok_or(SessionError::Unknown)?;
        let hearths = state.structure.ancestors(&mine.channel_id);
        let me = self.keys.public_key();
        let listeners: Vec<PublicKey> = self.voice_states(&mine.gid).into_iter().filter(|v| hearths.contains(&v.channel_id) && v.pubkey != me).map(|v| v.pubkey).collect();
        if listeners.is_empty() {
            return Err(SessionError::Other("No one is in the channels above yours.".into()));
        }
        let body = json!({"type": "voice_speak_request", "server_nostr_group_id": mine.gid, "channel_id": mine.channel_id});
        for p in &listeners {
            self.send_rpc(p, &body).await?;
        }
        Ok(())
    }

    /// Our mute and deafen, as others see them.
    pub async fn set_voice_flags(&self, self_mute: bool, self_deaf: bool) -> Result<()> {
        let mine = {
            let mut voice = self.voice.lock().unwrap_or_else(|e| e.into_inner());
            let Some(m) = voice.mine.as_mut() else { return Ok(()) };
            if (m.self_mute, m.self_deaf) == (self_mute, self_deaf) {
                return Ok(());
            }
            m.self_mute = self_mute;
            m.self_deaf = self_deaf;
            m.clone()
        };
        let _ = self.updates.send(Update::Voice(mine.gid.clone()));
        self.publish_voice("update", &mine, true).await
    }

    /// Publishes our state (kind 10070). With `notify`, Rails instances
    /// hear it too: Rails reads voice state only from kind-14 DMs to its
    /// providers (NostrVoiceStateSyncJob's format), not from 10070.
    async fn publish_voice(&self, action: &str, state: &VoiceState, notify: bool) -> Result<()> {
        let me = self.keys.public_key();
        let profile = self.profile(&me).unwrap_or_default();
        let hex = me.to_hex();
        let name = [&profile.display_name, &profile.name].into_iter().find(|n| !n.is_empty()).cloned().unwrap_or_else(|| hex[..8].to_owned());
        let content = json!({
            "type": "voice_state_sync",
            "action": action,
            "server_nostr_group_id": state.gid,
            "channel_id": state.channel_id,
            "user_id": &hex[..12],
            "user_pubkey": hex,
            "device_id": device_id(self),
            "username": name,
            "avatar_url": profile.picture,
            "self_mute": state.self_mute,
            "self_deaf": state.self_deaf,
            "server_mute": state.server_mute,
            "server_deaf": state.server_deaf,
            "broadcasting": state.broadcasting,
            "showcased": state.showcased,
        });
        let expires = Timestamp::now().as_secs() + EXPIRY;
        let event = EventBuilder::new(Kind::Custom(kinds::VOICE_STATE), content.to_string())
            .tags([Tag::parse(["h", &state.gid]).expect("h"), Tag::parse(["expiration", &expires.to_string()]).expect("expiration")])
            .finalize(&self.keys)
            .map_err(|e| SessionError::Other(e.to_string()))?;
        let event = self.fresh(event)?;
        self.voice.lock().unwrap_or_else(|e| e.into_inner()).published_at = Some(event.created_at);
        self.publish(&event).await?;
        if notify {
            let providers = self.server(&state.gid)?.map(|s| s.metadata.voice_providers).unwrap_or_default();
            let mut rails = content.clone();
            rails["profile_color"] = json!(profile.color);
            if action == "leave" {
                for k in ["username", "avatar_url", "profile_color"] {
                    rails[k] = Value::Null;
                }
            }
            for p in providers.iter().filter(|p| **p != me) {
                if let Err(e) = self.send_rpc(p, &rails).await {
                    tracing::warn!("voice state to provider {p}: {e}");
                }
            }
        }
        Ok(())
    }

    // ─── Tokens (Rails' voice_token RPC over kind 14) ────────────────────

    /// Our LiveKit server and keys, if we provide voice. Kept on this
    /// device only, encrypted to our own key.
    pub fn livekit_credentials(&self) -> Option<Credentials> {
        let sealed: String = self.store.get_setting(CREDENTIALS_KEY).ok().flatten()?;
        let me = self.keys.public_key();
        let plain = nip44::decrypt(self.keys.secret_key(), &me, &sealed).ok()?;
        serde_json::from_str(&plain).ok()
    }

    pub fn set_livekit_credentials(&self, creds: Option<&Credentials>) -> Result<()> {
        match creds {
            Some(c) => {
                let me = self.keys.public_key();
                let plain = serde_json::to_string(c).map_err(|e| SessionError::Other(e.to_string()))?;
                let sealed = nip44::encrypt(self.keys.secret_key(), &me, plain, nip44::Version::V2).map_err(|e| SessionError::Other(e.to_string()))?;
                self.store.set_setting(CREDENTIALS_KEY, &sealed)?;
            }
            None => self.store.set_setting(CREDENTIALS_KEY, &Option::<String>::None)?,
        }
        Ok(())
    }

    /// What `requester` may have in `channel_id` of `gid`: Rails' checks
    /// (a member, a voice channel, connect_voice; speak to publish).
    fn grant_for(&self, gid: &str, channel_id: &str, requester: &PublicKey, user_id: &str, name: &str, listen_only: bool) -> Option<Grant> {
        use crate::server::Permission;
        let state = self.server(gid).ok()??;
        let channel = state.channel(channel_id).filter(|c| c.kind == "voice")?;
        let member = state.is_member(requester) || state.is_owner(requester);
        if !member || !state.has(requester, Permission::ConnectVoice) || !state.can_read(requester, channel) {
            return None;
        }
        let profile = self.profile(requester).unwrap_or_default();
        Some(Grant {
            room: livekit_token::room_name(gid, channel_id),
            // Rails: the listener is `{id}_sub`, apart from the real one.
            identity: if listen_only { format!("{user_id}_sub") } else { user_id.to_owned() },
            name: name.to_owned(),
            can_publish: state.has(requester, Permission::Speak),
            listen_only,
            metadata: json!({"user_id": user_id, "avatar_url": profile.picture, "profile_color": profile.color, "pubkey": requester.to_hex()}),
        })
    }

    /// A ticket into a voice channel's room: minted here if we're one of
    /// its providers, otherwise asked of each provider in turn until one
    /// answers.
    pub async fn voice_ticket(&self, gid: &str, channel_id: &str) -> Result<VoiceTicket> {
        self.ticket(gid, channel_id, false).await
    }

    /// A listen-only ticket into a hearth's room, for hearing it from one
    /// of its embers (Rails' subscribe-only token).
    pub async fn voice_listen_ticket(&self, gid: &str, hearth_id: &str) -> Result<VoiceTicket> {
        self.ticket(gid, hearth_id, true).await
    }

    async fn ticket(&self, gid: &str, channel_id: &str, listen_only: bool) -> Result<VoiceTicket> {
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let me = self.keys.public_key();
        let hex = me.to_hex();
        let user_id = hex[..12].to_owned();
        let profile = self.profile(&me).unwrap_or_default();
        let name = [&profile.display_name, &profile.name].into_iter().find(|n| !n.is_empty()).cloned().unwrap_or_else(|| hex[..8].to_owned());
        let room = livekit_token::room_name(gid, channel_id);
        let providers = state.metadata.voice_providers.clone();
        if providers.is_empty() || !state.metadata.voice_enabled {
            return Err(SessionError::Other("Voice isn't set up on this server.".into()));
        }
        if providers.contains(&me) {
            if let Some(creds) = self.livekit_credentials() {
                let grant = self.grant_for(gid, channel_id, &me, &user_id, &name, listen_only).ok_or(SessionError::Other("You can't join this voice channel.".into()))?;
                let token = livekit_token::mint(&creds, &grant, Timestamp::now().as_secs());
                return Ok(VoiceTicket { url: creds.url, token, room });
            }
        }
        for provider in providers.iter().filter(|p| **p != me) {
            let request_id: String = (0..16).map(|_| format!("{:02x}", rand::random::<u8>())).collect();
            let (tx, rx) = tokio::sync::oneshot::channel();
            self.voice.lock().unwrap_or_else(|e| e.into_inner()).pending.insert(request_id.clone(), tx);
            let body = json!({
                "type": "voice_token_request",
                "request_id": request_id,
                "server_nostr_group_id": gid,
                "channel_id": channel_id,
                "user_pubkey": hex,
                "user_id": user_id,
                "user_display_name": name,
                "listen_only": listen_only,
            });
            let sent = self.send_rpc(provider, &body).await;
            let answer = match sent {
                Ok(()) => tokio::time::timeout(RPC_TIMEOUT, rx).await.ok().and_then(|r| r.ok()),
                Err(e) => {
                    tracing::warn!("voice token request to {provider}: {e}");
                    None
                }
            };
            self.voice.lock().unwrap_or_else(|e| e.into_inner()).pending.remove(&request_id);
            if let Some((url, token)) = answer {
                return Ok(VoiceTicket { url, token, room });
            }
        }
        Err(SessionError::Other("Voice provider did not respond in time. Please try again.".into()))
    }

    /// Rails' control envelope: kind 14, NIP-44 to `to`, tagged `p`.
    async fn send_rpc(&self, to: &PublicKey, body: &Value) -> Result<()> {
        let content = nip44::encrypt(self.keys.secret_key(), to, body.to_string(), nip44::Version::V2).map_err(|e| SessionError::Other(e.to_string()))?;
        let event = EventBuilder::new(Kind::PrivateDirectMessage, content)
            .tags([Tag::public_key(*to)])
            .finalize(&self.keys)
            .map_err(|e| SessionError::Other(e.to_string()))?;
        let report = self.pool.publish(&event).await?;
        if !report.any_accepted() {
            return Err(SessionError::NotPublished);
        }
        Ok(())
    }

    /// A voice control message from `sender`. True when it was one (it's
    /// not a DM then).
    pub(super) async fn voice_rpc(&self, sender: PublicKey, body: &str, sent: Timestamp) -> Result<bool> {
        let Some(v) = body.trim_start().starts_with('{').then(|| serde_json::from_str::<Value>(body).ok()).flatten() else {
            return Ok(false);
        };
        // Old requests met again (catching up on history after a restart)
        // are spent: the asker stopped waiting long ago, and a mute or move
        // from then must not happen now.
        let stale = Timestamp::now().as_secs().saturating_sub(sent.as_secs()) > RPC_MAX_AGE_SECS;
        if stale && v.get("type").and_then(Value::as_str).is_some_and(|t| t.starts_with("voice_")) {
            return Ok(true);
        }
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
        match v.get("type").and_then(Value::as_str) {
            Some("voice_token_response") => {
                let tx = self.voice.lock().unwrap_or_else(|e| e.into_inner()).pending.remove(&s("request_id"));
                if let Some(tx) = tx {
                    let _ = tx.send((s("livekit_url"), s("token")));
                }
                Ok(true)
            }
            // Rails' copy of someone's voice state, sent to providers; we
            // read voice state from kind 10070 instead.
            Some("voice_state_sync") => Ok(true),
            Some("voice_speak_request") => {
                // Only from someone in an ember below the channel we're in.
                let gid = s("server_nostr_group_id");
                let channel = s("channel_id");
                if let (Some(mine), Some(state)) = (self.my_voice().filter(|m| m.gid == gid), self.server(&gid)?) {
                    let asker_there = self.voice_states(&gid).iter().any(|v| v.pubkey == sender && v.channel_id == channel);
                    if asker_there && state.structure.ancestors(&channel).contains(&mine.channel_id) {
                        let _ = self.updates.send(Update::SpeakRequest { gid, channel_id: channel, from: sender });
                    }
                }
                Ok(true)
            }
            Some("voice_showcase") => {
                // From someone in a hearth above us, allowed to let us up.
                use crate::server::Permission;
                let gid = s("server_nostr_group_id");
                let on = v.get("on").and_then(Value::as_bool).unwrap_or(false);
                if let (Some(mine), Some(state)) = (self.my_voice().filter(|m| m.gid == gid && m.channel_id == s("channel_id")), self.server(&gid)?) {
                    let hearths = state.structure.ancestors(&mine.channel_id);
                    let above = self.voice_states(&gid).iter().any(|v| v.pubkey == sender && hearths.contains(&v.channel_id));
                    if above && state.has(&sender, Permission::ElevateVoice) {
                        self.set_showcased(on).await?;
                        let _ = self.updates.send(Update::Showcased { gid, on, by: sender });
                    }
                }
                Ok(true)
            }
            Some("voice_moderation") => {
                self.voice_moderated(sender, &v).await?;
                Ok(true)
            }
            Some("voice_token_request") => {
                if sender == self.keys.public_key() {
                    return Ok(true);
                }
                let gid = s("server_nostr_group_id");
                let me = self.keys.public_key();
                let providing = self.server(&gid)?.is_some_and(|st| st.metadata.voice_enabled && st.metadata.voice_providers.contains(&me));
                let Some(creds) = self.livekit_credentials().filter(|_| providing) else { return Ok(true) };
                // Rails lets an instance ask for its user; the user must be
                // a member either way.
                let requester = PublicKey::from_hex(&s("user_pubkey")).unwrap_or(sender);
                let user_id = Some(s("user_id")).filter(|u| !u.is_empty()).unwrap_or_else(|| requester.to_hex()[..12].to_owned());
                let name = Some(s("user_display_name")).filter(|n| !n.is_empty()).unwrap_or_else(|| user_id.clone());
                // Not allowed: no answer, as Rails does (the asker times out).
                let listen_only = v.get("listen_only").and_then(Value::as_bool).unwrap_or(false);
                let Some(grant) = self.grant_for(&gid, &s("channel_id"), &requester, &user_id, &name, listen_only) else { return Ok(true) };
                let token = livekit_token::mint(&creds, &grant, Timestamp::now().as_secs());
                let reply = json!({"type": "voice_token_response", "request_id": s("request_id"), "token": token, "livekit_url": creds.url});
                self.send_rpc(&sender, &reply).await?;
                Ok(true)
            }
            _ => Ok(false),
        }
    }

    // ─── Moderation ─────────────────────────────────────────────────────

    /// Asks `target`'s app to apply `action` (it checks our permission).
    pub async fn moderate_voice(&self, gid: &str, target: &PublicKey, action: &VoiceModeration) -> Result<()> {
        use crate::server::Permission;
        let state = self.server(gid)?.ok_or(SessionError::Unknown)?;
        let me = self.keys.public_key();
        let (name, on, channel, perm) = match action {
            VoiceModeration::ServerMute(on) => ("server_mute", *on, String::new(), Permission::MuteMembers),
            VoiceModeration::ServerDeafen(on) => ("server_deafen", *on, String::new(), Permission::DeafenMembers),
            VoiceModeration::Move(to) => ("move", true, to.clone(), Permission::MoveMembers),
            VoiceModeration::Disconnect => ("disconnect", true, String::new(), Permission::MoveMembers),
        };
        if !state.has(&me, perm) || state.is_owner(target) && !state.is_owner(&me) {
            return Err(SessionError::Other("You don't have permission to do that.".into()));
        }
        let body = json!({"type": "voice_moderation", "action": name, "on": on, "server_nostr_group_id": gid, "channel_id": channel});
        self.send_rpc(target, &body).await
    }

    /// A moderator's action on us: applied when they may, and we're in
    /// voice in that server.
    async fn voice_moderated(&self, sender: PublicKey, v: &Value) -> Result<()> {
        use crate::server::Permission;
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
        let gid = s("server_nostr_group_id");
        let Some(state) = self.server(&gid)? else { return Ok(()) };
        let Some(mine) = self.my_voice().filter(|m| m.gid == gid) else { return Ok(()) };
        let on = v.get("on").and_then(Value::as_bool).unwrap_or(true);
        let (action, perm) = match s("action").as_str() {
            "server_mute" => (VoiceModeration::ServerMute(on), Permission::MuteMembers),
            "server_deafen" => (VoiceModeration::ServerDeafen(on), Permission::DeafenMembers),
            "move" => (VoiceModeration::Move(s("channel_id")), Permission::MoveMembers),
            "disconnect" => (VoiceModeration::Disconnect, Permission::MoveMembers),
            _ => return Ok(()),
        };
        let me = self.keys.public_key();
        if !state.has(&sender, perm) || (state.is_owner(&me) && !state.is_owner(&sender)) {
            return Ok(());
        }
        match &action {
            VoiceModeration::ServerMute(on) | VoiceModeration::ServerDeafen(on) => {
                let updated = {
                    let mut voice = self.voice.lock().unwrap_or_else(|e| e.into_inner());
                    let Some(m) = voice.mine.as_mut() else { return Ok(()) };
                    if matches!(action, VoiceModeration::ServerMute(_)) {
                        m.server_mute = *on;
                    } else {
                        m.server_deaf = *on;
                    }
                    m.clone()
                };
                let _ = self.updates.send(Update::Voice(gid.clone()));
                self.publish_voice("update", &updated, true).await?;
            }
            VoiceModeration::Move(to) if state.channel(to).is_none_or(|c| c.kind != "voice") || *to == mine.channel_id => return Ok(()),
            _ => {}
        }
        let _ = self.updates.send(Update::VoiceModerated { gid, action, by: sender });
        Ok(())
    }

    /// A voice state from a relay.
    pub(super) async fn voice_event(&self, event: &Event) -> Result<()> {
        let Some(p) = parse(event) else { return Ok(()) };
        if !self.servers()?.contains(&p.gid) {
            return Ok(());
        }
        let me = self.keys.public_key();
        if event.pubkey == me && p.device_id == device_id(self) {
            // Our own echo. One saying we're in when this device hasn't
            // published this run is from a run that was killed: it gets a
            // leave, so others stop seeing us.
            let ours = self.voice.lock().unwrap_or_else(|e| e.into_inner()).published_at;
            if p.action != "leave" && ours.is_none() && p.expires > Timestamp::now().as_secs() {
                let ghost = VoiceState { pubkey: me, gid: p.gid, channel_id: p.channel_id, self_mute: false, self_deaf: false, server_mute: false, server_deaf: false, broadcasting: false, showcased: false, since: 0 };
                self.publish_voice("leave", &ghost, false).await?;
            }
            return Ok(());
        }
        let changed = {
            let mut voice = self.voice.lock().unwrap_or_else(|e| e.into_inner());
            let entry = voice.others.get(&event.pubkey);
            if entry.is_some_and(|(at, _, _)| *at >= event.created_at) {
                return Ok(());
            }
            let before = entry.and_then(|(_, s, _)| s.clone());
            let state = match p.action.as_str() {
                "leave" => None,
                _ if p.channel_id.is_empty() => None,
                _ => Some(VoiceState {
                    pubkey: event.pubkey,
                    gid: p.gid.clone(),
                    channel_id: p.channel_id.clone(),
                    self_mute: p.self_mute,
                    self_deaf: p.self_deaf,
                    server_mute: p.server_mute,
                    server_deaf: p.server_deaf,
                    broadcasting: p.broadcasting,
                    showcased: p.showcased,
                    // A refresh or an update keeps when they joined.
                    since: before
                        .as_ref()
                        .filter(|b| b.gid == p.gid && b.channel_id == p.channel_id)
                        .map_or(event.created_at.as_secs() as i64, |b| b.since),
                }),
            };
            voice.others.insert(event.pubkey, (event.created_at, state.clone(), p.expires));
            let mut gids: Vec<String> = Vec::new();
            if before != state {
                gids.extend(before.map(|b| b.gid));
                gids.extend(state.map(|s| s.gid));
                gids.dedup();
            }
            gids
        };
        for gid in changed {
            let _ = self.updates.send(Update::Voice(gid));
        }
        Ok(())
    }

    async fn catch_up_voice(&self) -> Result<()> {
        let gids = self.servers()?;
        if gids.is_empty() {
            return Ok(());
        }
        let filter = Filter::new().kind(Kind::Custom(kinds::VOICE_STATE)).custom_tags(SingleLetterTag::from_char('h').expect("h"), gids);
        for e in self.pool.fetch(vec![filter]).await? {
            self.voice_event(&e).await?;
        }
        Ok(())
    }

    /// Re-publishes our state before it expires, and drops others' expired
    /// ones.
    pub(super) fn spawn_voice(self: &std::sync::Arc<Self>) {
        let me = std::sync::Arc::downgrade(self);
        tokio::spawn(async move {
            // Who is in voice now. The subscription replays this too, but
            // it opens before anything listens to it.
            if let Some(s) = me.upgrade() {
                if let Err(e) = s.catch_up_voice().await {
                    tracing::warn!("voice catch-up: {e}");
                }
            }
            let mut sweep = tokio::time::interval(SWEEP);
            loop {
                sweep.tick().await;
                let Some(s) = me.upgrade() else { break };
                let now = Timestamp::now();
                let (refresh, expired) = {
                    let mut voice = s.voice.lock().unwrap_or_else(|e| e.into_inner());
                    let due = voice.published_at.is_none_or(|at| now.as_secs() >= at.as_secs() + REFRESH.as_secs());
                    let refresh = voice.mine.clone().filter(|_| due);
                    let mut expired = Vec::new();
                    for (_, state, exp) in voice.others.values_mut() {
                        if *exp <= now.as_secs() {
                            if let Some(gone) = state.take() {
                                expired.push(gone.gid);
                            }
                        }
                    }
                    (refresh, expired)
                };
                for gid in expired {
                    let _ = s.updates.send(Update::Voice(gid));
                }
                if let Some(mine) = refresh {
                    if let Err(e) = s.publish_voice("update", &mine, false).await {
                        tracing::warn!("voice refresh: {e}");
                    }
                }
            }
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_flutters_states() {
        let keys = Keys::generate();
        let content = json!({"type":"voice_state_sync","action":"join","server_nostr_group_id":"g1","channel_id":"c1","self_mute":true,"device_id":"d"});
        let e = EventBuilder::new(Kind::Custom(kinds::VOICE_STATE), content.to_string())
            .tags([Tag::parse(["h", "g1"]).unwrap(), Tag::parse(["expiration", "1000"]).unwrap()])
            .finalize(&keys)
            .unwrap();
        let p = parse(&e).unwrap();
        assert_eq!((p.action.as_str(), p.gid.as_str(), p.channel_id.as_str(), p.self_mute, p.expires), ("join", "g1", "c1", true, 1000));
        let other = EventBuilder::new(Kind::Custom(kinds::VOICE_STATE), "{\"type\":\"x\"}").finalize(&keys).unwrap();
        assert!(parse(&other).is_none());
    }
}
