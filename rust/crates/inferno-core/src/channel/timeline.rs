//! A channel's messages as the UI shows them, resolved from raw events.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use nostr::nips::nip44;
use nostr::prelude::*;

use super::keys::ChannelKeys;
use crate::kinds;
use crate::server::wire::Channel;
use crate::server::{Permission, ServerState};

#[derive(Debug, Clone, PartialEq)]
pub struct ChannelMessage {
    pub id: EventId,
    pub author: PublicKey,
    pub created_at: i64,
    /// Plaintext; `None` if the channel is encrypted and we lack the key.
    pub content: Option<String>,
    pub edited_at: Option<i64>,
    pub reply_to: Option<EventId>,
    pub spoiler: bool,
    pub mentions: Vec<PublicKey>,
    pub emoji: HashMap<String, String>,
    pub pinned: bool,
    /// Emoji → who reacted with it.
    pub reactions: BTreeMap<String, BTreeSet<PublicKey>>,
}

pub struct Timeline;

fn tag<'a>(e: &'a Event, name: &str) -> Option<&'a [String]> {
    e.tags.iter().map(|t| t.as_slice()).find(|s| s.first().map(String::as_str) == Some(name))
}

fn marked_e(e: &Event, marker: &str) -> Option<EventId> {
    e.tags.iter().map(|t| t.as_slice()).find_map(|s| {
        (s.first().map(String::as_str) == Some("e") && s.iter().skip(2).any(|m| m == marker))
            .then(|| EventId::from_hex(s.get(1)?).ok())
            .flatten()
    })
}

fn first_e(e: &Event) -> Option<EventId> {
    e.tags.event_ids().next()
}

impl Timeline {
    /// Resolves `channel`'s timeline from `events` (any order, any kinds; ones
    /// for other channels are skipped). Oldest first.
    pub fn resolve(
        state: &ServerState,
        channel: &Channel,
        events: &[Event],
        keys: &ChannelKeys,
        blocked: &HashSet<PublicKey>,
    ) -> Vec<ChannelMessage> {
        let Some(group) = channel.group_id.as_deref() else { return Vec::new() };
        let ours = |e: &&Event| tag(e, "h").and_then(|t| t.get(1)).map(String::as_str) == Some(group);

        // Whoever was banned, blocked, or sending during a timeout doesn't
        // exist for this timeline, whatever their client did.
        let counts = |e: &Event| {
            !blocked.contains(&e.pubkey)
                && !state.is_banned(&e.pubkey)
                && !state.was_timed_out_at(&e.pubkey, e.created_at.as_secs() as i64)
        };

        let sealed = |e: &Event| tag(e, "encrypted").and_then(|t| t.get(1)).map(String::as_str) == Some("nip44");
        // A message whose sealing doesn't match the channel is dropped:
        // plaintext in an encrypted channel is a leak or a forgery, and
        // sealed messages in a channel that turned encryption off belong to
        // history that was purged (as Rails does) when it did.
        let fits = |e: &Event| sealed(e) == channel.encrypted;
        let open = |e: &Event| -> Option<String> {
            if !sealed(e) {
                return Some(e.content.clone());
            }
            let pk = tag(e, "channel_pubkey").and_then(|t| t.get(1))?;
            let key = keys.get(pk)?;
            nip44::decrypt(key.secret_key(), &e.pubkey, &e.content).ok()
        };

        let mut messages: BTreeMap<EventId, ChannelMessage> = BTreeMap::new();
        let mut edits: Vec<&Event> = Vec::new();
        let mut deletes: Vec<&Event> = Vec::new();
        let mut pins: Vec<&Event> = Vec::new();
        let mut reactions: Vec<&Event> = Vec::new();

        for e in events.iter().filter(ours).filter(|e| counts(e)) {
            if matches!(e.kind.as_u16(), kinds::CHANNEL_MESSAGE) && !fits(e) {
                continue;
            }
            match e.kind.as_u16() {
                kinds::CHANNEL_MESSAGE if marked_e(e, "edit").is_some() => edits.push(e),
                kinds::CHANNEL_MESSAGE => {
                    let content = open(e);
                    messages.insert(
                        e.id,
                        ChannelMessage {
                            id: e.id,
                            author: e.pubkey,
                            created_at: e.created_at.as_secs() as i64,
                            content,
                            edited_at: None,
                            reply_to: marked_e(e, "reply"),
                            spoiler: tag(e, "spoiler").is_some(),
                            mentions: e.tags.public_keys().collect(),
                            emoji: e
                                .tags
                                .iter()
                                .map(|t| t.as_slice())
                                .filter(|s| s.first().map(String::as_str) == Some("emoji"))
                                .filter_map(|s| Some((s.get(1)?.clone(), s.get(2)?.clone())))
                                .collect(),
                            pinned: false,
                            reactions: BTreeMap::new(),
                        },
                    );
                }
                kinds::CHANNEL_DELETE => deletes.push(e),
                kinds::PIN => pins.push(e),
                kinds::REACTION => reactions.push(e),
                _ => {}
            }
        }

        // Edits: only the author's, applied oldest to newest.
        edits.sort_by_key(|e| e.created_at);
        for e in edits {
            let Some(target) = marked_e(e, "edit") else { continue };
            if let Some(m) = messages.get_mut(&target) {
                if m.author == e.pubkey {
                    if let Some(text) = open(e) {
                        m.content = Some(text);
                        m.edited_at = Some(e.created_at.as_secs() as i64);
                    }
                }
            }
        }

        // Pins: the newest pin event from a moderator wins.
        pins.sort_by_key(|e| e.created_at);
        for e in pins {
            if !state.has(&e.pubkey, Permission::ManageMessages) {
                continue;
            }
            let pinned = tag(e, "pinned").and_then(|t| t.get(1)).map(String::as_str) == Some("true");
            if let Some(m) = first_e(e).and_then(|id| messages.get_mut(&id)) {
                m.pinned = pinned;
            }
        }

        // Reactions in order; "-" clears the reactor's reactions (Rails).
        reactions.sort_by_key(|e| e.created_at);
        for e in reactions {
            let Some(m) = first_e(e).and_then(|id| messages.get_mut(&id)) else { continue };
            if e.content == "-" {
                for who in m.reactions.values_mut() {
                    who.remove(&e.pubkey);
                }
                m.reactions.retain(|_, who| !who.is_empty());
            } else if !e.content.is_empty() && state.has(&e.pubkey, Permission::AddReactions) {
                m.reactions.entry(e.content.clone()).or_default().insert(e.pubkey);
            }
        }

        // Deletions: by the author or a moderator.
        for e in deletes {
            for id in e.tags.event_ids() {
                if let Some(m) = messages.get(&id) {
                    if m.author == e.pubkey || state.has(&e.pubkey, Permission::ManageMessages) {
                        messages.remove(&id);
                    }
                }
            }
        }

        let mut out: Vec<ChannelMessage> = messages.into_values().collect();
        out.sort_by_key(|m| (m.created_at, m.id));
        out
    }
}

#[cfg(test)]
mod tests;
