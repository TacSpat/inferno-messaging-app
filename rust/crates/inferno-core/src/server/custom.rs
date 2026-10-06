//! Publishing custom emoji (31754) and stickers (31755).
//!
//! Each kind is one list per server, so every change republishes the whole
//! list, built from the server's current effective list so nobody else's
//! items are lost. Flutter never published these at all: emoji added there
//! were invisible to everyone else.

use nostr::prelude::*;

use super::state::ServerState;
use super::wire::{Emoji, Sticker};
use super::Permission;
use crate::{dtag, kinds};

/// Rails' limits (`server_emoji.rb`, `server_sticker.rb`).
pub const MAX_EMOJIS: usize = 50;
pub const MAX_STICKERS: usize = 30;
const MAX_EMOJI_NAME: usize = 32;
const MAX_STICKER_NAME: usize = 50;

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum CustomError {
    #[error("you don't have permission to do that")]
    NotAllowed,
    #[error("emoji names are 1-32 lowercase letters, digits or underscores")]
    BadEmojiName,
    #[error("sticker names are 1-50 characters")]
    BadStickerName,
    #[error("\"{0}\" is already taken")]
    NameTaken(String),
    #[error("this server has reached its limit of {0}")]
    LimitReached(usize),
    #[error("images must be https URLs")]
    BadUrl,
    #[error("no item named \"{0}\"")]
    NotFound(String),
    #[error("could not sign: {0}")]
    Build(String),
}

pub fn valid_emoji_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_EMOJI_NAME
        && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')
}

fn check_url(url: &str) -> Result<(), CustomError> {
    if url.starts_with("https://") && url.len() > "https://".len() { Ok(()) } else { Err(CustomError::BadUrl) }
}

fn sign(keys: &Keys, kind: u16, d: String, gid: &str, rows: Vec<Vec<String>>) -> Result<Event, CustomError> {
    let mut tags = vec![Tag::identifier(d), Tag::parse(["server", gid]).expect("tag")];
    tags.extend(rows.into_iter().map(|r| Tag::parse(r).expect("tag")));
    EventBuilder::new(Kind::Custom(kind), "")
        .tags(tags)
        .finalize(keys)
        .map_err(|e| CustomError::Build(e.to_string()))
}

fn hex(pk: Option<PublicKey>) -> String {
    pk.map(|p| p.to_hex()).unwrap_or_default()
}

fn emoji_event(keys: &Keys, state: &ServerState, list: &[Emoji]) -> Result<Event, CustomError> {
    let rows = list
        .iter()
        .map(|e| vec!["emoji".into(), e.name.clone(), e.url.clone(), hex(e.creator)])
        .collect();
    sign(keys, kinds::SERVER_EMOJI, dtag::emojis(&state.gid), &state.gid, rows)
}

fn sticker_event(keys: &Keys, state: &ServerState, list: &[Sticker]) -> Result<Event, CustomError> {
    let rows = list
        .iter()
        .map(|s| vec!["sticker".into(), s.name.clone(), s.description.clone(), s.url.clone(), hex(s.creator)])
        .collect();
    sign(keys, kinds::SERVER_STICKERS, dtag::stickers(&state.gid), &state.gid, rows)
}

pub fn add_emoji(keys: &Keys, state: &ServerState, name: &str, url: &str) -> Result<Event, CustomError> {
    let me = keys.public_key();
    if !state.has(&me, Permission::CreateEmojis) && !state.has(&me, Permission::ManageEmojis) {
        return Err(CustomError::NotAllowed);
    }
    if !valid_emoji_name(name) {
        return Err(CustomError::BadEmojiName);
    }
    check_url(url)?;
    if state.emojis.iter().any(|e| e.name == name) {
        return Err(CustomError::NameTaken(name.into()));
    }
    if state.emojis.len() >= MAX_EMOJIS {
        return Err(CustomError::LimitReached(MAX_EMOJIS));
    }
    let mut list = state.emojis.clone();
    list.push(Emoji { name: name.into(), url: url.into(), creator: Some(me) });
    emoji_event(keys, state, &list)
}

/// Removing needs `manage_emojis`, as in Rails.
pub fn remove_emoji(keys: &Keys, state: &ServerState, name: &str) -> Result<Event, CustomError> {
    if !state.has(&keys.public_key(), Permission::ManageEmojis) {
        return Err(CustomError::NotAllowed);
    }
    let list: Vec<Emoji> = state.emojis.iter().filter(|e| e.name != name).cloned().collect();
    if list.len() == state.emojis.len() {
        return Err(CustomError::NotFound(name.into()));
    }
    emoji_event(keys, state, &list)
}

pub fn add_sticker(
    keys: &Keys,
    state: &ServerState,
    name: &str,
    description: &str,
    url: &str,
) -> Result<Event, CustomError> {
    let me = keys.public_key();
    if !state.has(&me, Permission::CreateStickers) && !state.has(&me, Permission::ManageEmojis) {
        return Err(CustomError::NotAllowed);
    }
    let name = name.trim();
    if name.is_empty() || name.chars().count() > MAX_STICKER_NAME {
        return Err(CustomError::BadStickerName);
    }
    check_url(url)?;
    // Rails: unique per server, case-insensitive.
    if state.stickers.iter().any(|s| s.name.eq_ignore_ascii_case(name)) {
        return Err(CustomError::NameTaken(name.into()));
    }
    if state.stickers.len() >= MAX_STICKERS {
        return Err(CustomError::LimitReached(MAX_STICKERS));
    }
    let mut list = state.stickers.clone();
    list.push(Sticker { name: name.into(), description: description.into(), url: url.into(), creator: Some(me) });
    sticker_event(keys, state, &list)
}

pub fn remove_sticker(keys: &Keys, state: &ServerState, name: &str) -> Result<Event, CustomError> {
    if !state.has(&keys.public_key(), Permission::ManageEmojis) {
        return Err(CustomError::NotAllowed);
    }
    let list: Vec<Sticker> = state.stickers.iter().filter(|s| !s.name.eq_ignore_ascii_case(name)).cloned().collect();
    if list.len() == state.stickers.len() {
        return Err(CustomError::NotFound(name.into()));
    }
    sticker_event(keys, state, &list)
}

/// NIP-30 `(shortcode, url)` pairs for the server emoji used in `content`,
/// for a message's `emoji` tags (what Rails attaches when publishing).
pub fn emoji_tags(state: &ServerState, content: &str) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    let mut rest = content;
    while let Some(start) = rest.find(':') {
        let after = &rest[start + 1..];
        let Some(end) = after.find(':') else { break };
        let code = &after[..end];
        if valid_emoji_name(code) {
            if let Some(e) = state.emojis.iter().find(|e| e.name == code) {
                if !out.iter().any(|(c, _)| c == code) {
                    out.push((e.name.clone(), e.url.clone()));
                }
            }
            rest = &after[end + 1..];
        } else {
            // Not a shortcode; the closing colon may open the next one.
            rest = after;
        }
    }
    out
}

#[cfg(test)]
mod tests;
