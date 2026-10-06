//! Builders for outgoing channel events. Each checks the sender's standing
//! first, so a client can't send what receivers would drop anyway.

use nostr::nips::nip44;
use nostr::prelude::*;

use crate::kinds;
use crate::server::state::SendDenied;
use crate::server::wire::Channel;
use crate::server::{Permission, ServerState};

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum SendError {
    #[error("not allowed: {0:?}")]
    Denied(SendDenied),
    #[error("this channel has no group id")]
    NoGroup,
    /// An encrypted channel without a key would send plaintext; Flutter's
    /// create path did exactly that.
    #[error("encrypted channel has no key yet; refusing to send plaintext")]
    MissingChannelKey,
    #[error("could not build the event: {0}")]
    Build(String),
}

#[derive(Debug, Default, Clone)]
pub struct Outgoing<'a> {
    pub content: &'a str,
    pub reply_to: Option<EventId>,
    pub spoiler: bool,
    /// The content is a sticker's URL (Rails' `["sticker"]` tag).
    pub sticker: bool,
    pub mentions: Vec<PublicKey>,
    /// NIP-30 `(shortcode, url)` for custom emoji used in `content`.
    pub emoji: Vec<(String, String)>,
}

fn group(channel: &Channel) -> Result<&str, SendError> {
    channel.group_id.as_deref().ok_or(SendError::NoGroup)
}

fn h(group: &str) -> Tag {
    Tag::parse(["h", group]).expect("h tag")
}

fn sign(keys: &Keys, kind: u16, content: String, tags: Vec<Tag>) -> Result<Event, SendError> {
    EventBuilder::new(Kind::Custom(kind), content)
        .tags(tags)
        .finalize(keys)
        .map_err(|e| SendError::Build(e.to_string()))
}

/// Encrypts for an encrypted channel the way Rails does: NIP-44 between the
/// sender and the channel's public key, tagged so receivers know.
fn seal_content(
    keys: &Keys,
    channel: &Channel,
    content: &str,
    tags: &mut Vec<Tag>,
) -> Result<String, SendError> {
    if !channel.encrypted {
        return Ok(content.to_owned());
    }
    let pubkey_hex = channel.channel_pubkey.as_deref().ok_or(SendError::MissingChannelKey)?;
    let channel_pk = PublicKey::from_hex(pubkey_hex).map_err(|_| SendError::MissingChannelKey)?;
    let sealed = nip44::encrypt(keys.secret_key(), &channel_pk, content, nip44::Version::V2)
        .map_err(|e| SendError::Build(e.to_string()))?;
    tags.push(Tag::parse(["encrypted", "nip44"]).expect("tag"));
    tags.push(Tag::parse(["channel_pubkey", pubkey_hex]).expect("tag"));
    Ok(sealed)
}

pub fn message(
    keys: &Keys,
    state: &ServerState,
    channel: &Channel,
    msg: &Outgoing,
    now: i64,
) -> Result<Event, SendError> {
    state.can_send(&keys.public_key(), channel, now).map_err(SendError::Denied)?;
    let mut tags = vec![h(group(channel)?)];
    if let Some(parent) = msg.reply_to {
        tags.push(Tag::parse(["e", &parent.to_hex(), "", "reply"]).expect("tag"));
    }
    if msg.spoiler {
        tags.push(Tag::parse(["spoiler"]).expect("tag"));
    }
    if msg.sticker {
        tags.push(Tag::parse(["sticker"]).expect("tag"));
    }
    tags.extend(msg.mentions.iter().map(|p| Tag::public_key(*p)));
    for (code, url) in &msg.emoji {
        tags.push(Tag::parse(["emoji", code, url]).expect("tag"));
    }
    let content = seal_content(keys, channel, msg.content, &mut tags)?;
    sign(keys, kinds::CHANNEL_MESSAGE, content, tags)
}

/// An edit is a new kind 9 pointing at the original with an `edit` marker.
pub fn edit(
    keys: &Keys,
    state: &ServerState,
    channel: &Channel,
    original: &Event,
    new_content: &str,
    now: i64,
) -> Result<Event, SendError> {
    if original.pubkey != keys.public_key() {
        return Err(SendError::Denied(SendDenied::NoPermission));
    }
    state.can_send(&keys.public_key(), channel, now).map_err(SendError::Denied)?;
    let mut tags = vec![h(group(channel)?), Tag::parse(["e", &original.id.to_hex(), "", "edit"]).expect("tag")];
    let content = seal_content(keys, channel, new_content, &mut tags)?;
    sign(keys, kinds::CHANNEL_MESSAGE, content, tags)
}

pub fn delete(keys: &Keys, state: &ServerState, channel: &Channel, target: &Event) -> Result<Event, SendError> {
    let me = keys.public_key();
    if target.pubkey != me && !state.has(&me, Permission::ManageMessages) {
        return Err(SendError::Denied(SendDenied::NoPermission));
    }
    sign(keys, kinds::CHANNEL_DELETE, String::new(), vec![h(group(channel)?), Tag::event(target.id)])
}

pub fn pin(keys: &Keys, state: &ServerState, channel: &Channel, target: EventId, pinned: bool) -> Result<Event, SendError> {
    if !state.has(&keys.public_key(), Permission::ManageMessages) {
        return Err(SendError::Denied(SendDenied::NoPermission));
    }
    let tags = vec![
        h(group(channel)?),
        Tag::event(target),
        Tag::parse(["pinned", if pinned { "true" } else { "false" }]).expect("tag"),
    ];
    sign(keys, kinds::PIN, String::new(), tags)
}

/// `emoji` = "-" removes all of the sender's reactions on the message, which
/// is what Rails does with it.
pub fn react(
    keys: &Keys,
    state: &ServerState,
    channel: &Channel,
    target: &Event,
    emoji: &str,
) -> Result<Event, SendError> {
    let me = keys.public_key();
    if !state.is_member(&me) || state.is_banned(&me) || !state.has(&me, Permission::AddReactions) {
        return Err(SendError::Denied(SendDenied::NoPermission));
    }
    let tags = vec![h(group(channel)?), Tag::event(target.id), Tag::public_key(target.pubkey)];
    sign(keys, kinds::REACTION, emoji.to_owned(), tags)
}
