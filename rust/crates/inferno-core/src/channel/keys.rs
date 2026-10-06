//! Encrypted-channel keys.
//!
//! Rails kept each channel's secret key on the server that created it and
//! never sent it anywhere, so nobody else could read encrypted channels. Here
//! whoever creates or rotates a channel key gift-wraps it (NIP-59) to every
//! member who can read the channel. Receivers accept a share only if the
//! sender may manage channels and the key matches the public key the
//! channel's structure announces, so a forged share can't redirect anything.
//!
//! The shares stay in the cache as gift wraps, encrypted to our identity, so
//! channel secrets are never stored in plain text.

use std::collections::HashMap;

use nostr::nips::nip59::{GiftWrapBuilder, UnwrappedGift};
use nostr::prelude::*;
use serde::{Deserialize, Serialize};

use crate::kinds;
use crate::server::{Permission, ServerState};

#[derive(Serialize, Deserialize)]
struct ShareBody {
    channel_pubkey: String,
    channel_secret: String,
}

/// A fresh keypair for a new encrypted channel (or a rotation). Announce
/// its public key in the structure, then [`share`] it before anyone sends.
pub fn generate() -> Keys {
    Keys::generate()
}

/// Gift wraps of `channel_key` to each recipient.
pub fn share(
    keys: &Keys,
    gid: &str,
    channel_id: &str,
    channel_key: &Keys,
    recipients: impl IntoIterator<Item = PublicKey>,
) -> Result<Vec<Event>, String> {
    let body = serde_json::to_string(&ShareBody {
        channel_pubkey: channel_key.public_key().to_hex(),
        channel_secret: channel_key.secret_key().to_secret_hex(),
    })
    .map_err(|e| e.to_string())?;
    recipients
        .into_iter()
        .map(|to| {
            let mut rumor = EventBuilder::new(Kind::Custom(kinds::CHANNEL_KEY_SHARE), body.clone())
                .tags([
                    Tag::parse(["server", gid]).expect("tag"),
                    Tag::parse(["channel", channel_id]).expect("tag"),
                    Tag::public_key(to),
                ])
                .finalize_unsigned(keys.public_key());
            rumor.ensure_id();
            GiftWrapBuilder::new(to, rumor).finalize(keys).map_err(|e| e.to_string())
        })
        .collect()
}

/// Who should hold a channel's key: everyone who can read messages.
pub fn readers(state: &ServerState) -> Vec<PublicKey> {
    let mut out: Vec<PublicKey> = state
        .members
        .keys()
        .copied()
        .filter(|pk| state.has(pk, Permission::ReadMessages))
        .collect();
    if let Some(owner) = state.owner {
        if !out.contains(&owner) {
            out.push(owner);
        }
    }
    out
}

/// Channel keys we hold, by channel public key (hex). Old keys stay after a
/// rotation so history sealed under them still opens.
#[derive(Default)]
pub struct ChannelKeys {
    by_pubkey: HashMap<String, Keys>,
}

impl ChannelKeys {
    /// Adds the key from a gift wrap if it's a valid share for a channel in
    /// `state`. Returns the channel id it unlocked.
    pub fn accept(&mut self, me: &Keys, state: &ServerState, gift_wrap: &Event) -> Option<String> {
        let UnwrappedGift { sender, rumor } = UnwrappedGift::from_gift_wrap(me, gift_wrap).ok()?;
        if rumor.kind != Kind::Custom(kinds::CHANNEL_KEY_SHARE) || rumor.pubkey != sender {
            return None;
        }
        let tag = |name: &str| {
            rumor.tags.iter().find_map(|t| {
                let s = t.as_slice();
                (s.first().map(String::as_str) == Some(name)).then(|| s.get(1).cloned()).flatten()
            })
        };
        if tag("server").as_deref() != Some(state.gid.as_str()) {
            return None;
        }
        if !state.has(&sender, Permission::ManageChannels) {
            return None;
        }
        let channel_id = tag("channel")?;
        let body: ShareBody = serde_json::from_str(&rumor.content).ok()?;
        let key = Keys::parse(&body.channel_secret).ok()?;
        // The secret must produce the public key the share claims...
        if key.public_key().to_hex() != body.channel_pubkey {
            return None;
        }
        // ...and the channel must currently announce that key. Keys accepted
        // earlier are kept, so history from before a rotation still opens,
        // but nobody is handed a key the channel has already moved on from.
        let channel = state.channel(&channel_id)?;
        if !channel.encrypted || channel.channel_pubkey.as_deref() != Some(body.channel_pubkey.as_str()) {
            return None;
        }
        self.by_pubkey.insert(body.channel_pubkey, key);
        Some(channel_id)
    }

    pub fn get(&self, channel_pubkey_hex: &str) -> Option<&Keys> {
        self.by_pubkey.get(channel_pubkey_hex)
    }

    pub fn insert(&mut self, key: Keys) {
        self.by_pubkey.insert(key.public_key().to_hex(), key);
    }
}
