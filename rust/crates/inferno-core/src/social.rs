//! Friends and DM conversations, derived from the DMs we've seen.
//!
//! Every control message travels inside a NIP-17 DM, and our own sends are
//! wrapped to ourselves too, so replaying them in order gives every device
//! the same friend list without a separate contact table to keep in sync.
//! The payload types are Rails' (`dm_messages_controller`,
//! `friendships_controller`); Rails and Flutter sent them as signed kind 14
//! in the clear, which showed relays who talks to whom.

use std::collections::HashMap;

use nostr_sdk::prelude::{EventId, PublicKey};
use serde_json::{json, Value};

/// What a DM body carries.
#[derive(Debug, Clone, PartialEq)]
pub enum Payload {
    Message { content: String, files: Vec<String>, spoiler: bool },
    Edit { id: EventId, content: String },
    Delete { id: EventId },
    /// Flutter's encrypted reactions (Rails ignored them).
    Reaction { id: EventId, emoji: String, add: bool },
    FriendRequest,
    FriendResponse(Response),
    /// Voice/RPC control messages and anything newer than us.
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Response {
    Accepted,
    Declined,
    Removed,
}

impl Payload {
    /// Plain text is a message; JSON is dispatched on `type`.
    pub fn parse(body: &str) -> Payload {
        let Some(v) = body.trim_start().starts_with('{').then(|| serde_json::from_str::<Value>(body).ok()).flatten() else {
            return Payload::Message { content: body.to_owned(), files: vec![], spoiler: false };
        };
        let s = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
        let id = |k: &str| v.get(k).and_then(Value::as_str).and_then(|h| EventId::from_hex(h).ok());
        match v.get("type").and_then(Value::as_str) {
            Some("message") | None if v.get("content").is_some() => Payload::Message {
                content: s("content"),
                files: v
                    .get("files")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                    .unwrap_or_default(),
                spoiler: v.get("spoiler").and_then(Value::as_bool).unwrap_or(false),
            },
            Some("message_edit") => id("event_id").map_or(Payload::Other, |id| Payload::Edit { id, content: s("content") }),
            Some("message_delete") => id("event_id").map_or(Payload::Other, |id| Payload::Delete { id }),
            Some("reaction") => id("e").map_or(Payload::Other, |id| Payload::Reaction {
                id,
                emoji: s("emoji"),
                add: s("action") != "remove",
            }),
            Some("friend_request") => Payload::FriendRequest,
            Some("friend_response") => match s("status").as_str() {
                "accepted" => Payload::FriendResponse(Response::Accepted),
                "declined" => Payload::FriendResponse(Response::Declined),
                "removed" => Payload::FriendResponse(Response::Removed),
                _ => Payload::Other,
            },
            _ => Payload::Other,
        }
    }

    /// The body to send. Plain messages stay plain text, as Rails sends them.
    pub fn body(&self) -> String {
        match self {
            Payload::Message { content, files, spoiler } if files.is_empty() && !spoiler => content.clone(),
            Payload::Message { content, files, spoiler } => {
                json!({"type": "message", "content": content, "files": files, "spoiler": spoiler}).to_string()
            }
            Payload::Edit { id, content } => json!({"type": "message_edit", "event_id": id.to_hex(), "content": content}).to_string(),
            Payload::Delete { id } => json!({"type": "message_delete", "event_id": id.to_hex()}).to_string(),
            Payload::Reaction { id, emoji, add } => json!({
                "type": "reaction", "action": if *add { "add" } else { "remove" }, "e": id.to_hex(), "emoji": emoji
            })
            .to_string(),
            Payload::FriendRequest => json!({"type": "friend_request"}).to_string(),
            Payload::FriendResponse(r) => json!({"type": "friend_response", "status": match r {
                Response::Accepted => "accepted",
                Response::Declined => "declined",
                Response::Removed => "removed",
            }})
            .to_string(),
            Payload::Other => String::new(),
        }
    }
}

/// Rails' Contact statuses, minus `blocked` (blocks are their own list) and
/// `declined` (which shows as no relationship).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Friendship {
    #[default]
    None,
    Outgoing,
    Incoming,
    Accepted,
}

/// One decrypted DM, as the rumor cache keeps it.
#[derive(Debug, Clone, PartialEq)]
pub struct Rumor {
    pub id: EventId,
    pub sender: PublicKey,
    /// The other side of the conversation (ourselves for Saved Messages).
    pub counterparty: PublicKey,
    pub created_at: i64,
    pub body: String,
}

/// Replays friend control messages, oldest first, into a status per person.
/// `ignored` holds requests dismissed locally (Rails' Ignore sends nothing),
/// with when; a newer request shows again.
pub fn friendships(me: &PublicKey, rumors: &[Rumor], ignored: &HashMap<PublicKey, i64>) -> HashMap<PublicKey, Friendship> {
    let mut sorted: Vec<&Rumor> = rumors.iter().filter(|r| r.counterparty != *me).collect();
    // Within one second a request comes before any answer to it: the two
    // sides' clocks can't order them, but causality can.
    let rank = |r: &Rumor| match Payload::parse(&r.body) {
        Payload::FriendRequest => 0,
        Payload::FriendResponse(Response::Removed) => 2,
        _ => 1,
    };
    sorted.sort_by_key(|r| (r.created_at, rank(r), r.id));
    let mut out: HashMap<PublicKey, Friendship> = HashMap::new();
    for r in sorted {
        let from_me = r.sender == *me;
        let status = out.entry(r.counterparty).or_default();
        use Friendship::*;
        *status = match (Payload::parse(&r.body), from_me, *status) {
            // Asking someone who already asked us is a yes.
            (Payload::FriendRequest, true, Incoming) => Accepted,
            (Payload::FriendRequest, true, None) => Outgoing,
            (Payload::FriendRequest, false, Outgoing) => Accepted,
            (Payload::FriendRequest, false, None) => Incoming,
            (Payload::FriendResponse(Response::Accepted), true, Incoming) => Accepted,
            (Payload::FriendResponse(Response::Accepted), false, Outgoing) => Accepted,
            (Payload::FriendResponse(Response::Declined), true, Incoming) => None,
            (Payload::FriendResponse(Response::Declined), false, Outgoing) => None,
            (Payload::FriendResponse(Response::Removed), _, _) => None,
            (_, _, s) => s,
        };
    }
    // Ignored requests stay hidden until the person asks again.
    for (pk, at) in ignored {
        let last_request = rumors
            .iter()
            .filter(|r| r.sender == *pk && Payload::parse(&r.body) == Payload::FriendRequest)
            .map(|r| r.created_at)
            .max();
        if out.get(pk) == Some(&Friendship::Incoming) && last_request.is_some_and(|t| t <= *at) {
            out.insert(*pk, Friendship::None);
        }
    }
    out.retain(|_, s| *s != Friendship::None);
    out
}

/// A message in a DM conversation, with edits, deletes and reactions applied.
#[derive(Debug, Clone, PartialEq)]
pub struct DmMessage {
    pub id: EventId,
    pub author: PublicKey,
    pub created_at: i64,
    pub content: String,
    pub files: Vec<String>,
    pub spoiler: bool,
    pub edited: bool,
    /// emoji → who reacted.
    pub reactions: Vec<(String, Vec<PublicKey>)>,
}

/// The messages of one conversation, oldest first. Only a message's author
/// can edit or delete it.
pub fn conversation(rumors: &[Rumor]) -> Vec<DmMessage> {
    let mut sorted: Vec<&Rumor> = rumors.iter().collect();
    sorted.sort_by_key(|r| (r.created_at, r.id));
    let mut messages: Vec<DmMessage> = Vec::new();
    let mut index: HashMap<EventId, usize> = HashMap::new();
    let mut deleted = Vec::new();
    for r in &sorted {
        if let Payload::Message { content, files, spoiler } = Payload::parse(&r.body) {
            index.insert(r.id, messages.len());
            messages.push(DmMessage {
                id: r.id,
                author: r.sender,
                created_at: r.created_at,
                content,
                files,
                spoiler,
                edited: false,
                reactions: vec![],
            });
        }
    }
    for r in &sorted {
        match Payload::parse(&r.body) {
            Payload::Edit { id, content } => {
                if let Some(m) = index.get(&id).map(|&i| &mut messages[i]).filter(|m| m.author == r.sender) {
                    m.content = content;
                    m.edited = true;
                }
            }
            Payload::Delete { id } => {
                if index.get(&id).is_some_and(|&i| messages[i].author == r.sender) {
                    deleted.push(id);
                }
            }
            Payload::Reaction { id, emoji, add } => {
                let Some(m) = index.get(&id).map(|&i| &mut messages[i]) else { continue };
                let slot = match m.reactions.iter().position(|(e, _)| *e == emoji) {
                    Some(i) => i,
                    None => {
                        m.reactions.push((emoji, vec![]));
                        m.reactions.len() - 1
                    }
                };
                let who = &mut m.reactions[slot].1;
                who.retain(|p| *p != r.sender);
                if add {
                    who.push(r.sender);
                }
                m.reactions.retain(|(_, w)| !w.is_empty());
            }
            _ => {}
        }
    }
    messages.retain(|m| !deleted.contains(&m.id));
    messages
}

#[cfg(test)]
mod tests {
    use super::*;
    use nostr_sdk::prelude::Keys;

    fn rumor(n: u8, sender: &PublicKey, counterparty: &PublicKey, at: i64, body: &str) -> Rumor {
        Rumor { id: EventId::from_slice(&[n; 32]).unwrap(), sender: *sender, counterparty: *counterparty, created_at: at, body: body.into() }
    }

    #[test]
    fn payloads_round_trip_and_rails_shapes_parse() {
        let id = EventId::from_slice(&[7; 32]).unwrap();
        for p in [
            Payload::Message { content: "hi".into(), files: vec![], spoiler: false },
            Payload::Message { content: "look".into(), files: vec!["https://x/a.png".into()], spoiler: true },
            Payload::Edit { id, content: "fixed".into() },
            Payload::Delete { id },
            Payload::Reaction { id, emoji: "🔥".into(), add: false },
            Payload::FriendRequest,
            Payload::FriendResponse(Response::Removed),
        ] {
            assert_eq!(Payload::parse(&p.body()), p);
        }
        assert_eq!(Payload::parse("hi"), Payload::Message { content: "hi".into(), files: vec![], spoiler: false });
        assert_eq!(Payload::parse(r#"{"type":"friend_request","from":"abc"}"#), Payload::FriendRequest);
        assert_eq!(Payload::parse(r#"{"type":"voice_token_request"}"#), Payload::Other);
        assert_eq!(Payload::parse("{not json"), Payload::Message { content: "{not json".into(), files: vec![], spoiler: false });
    }

    #[test]
    fn friend_requests_replay_to_the_same_status_everywhere() {
        let (me, a, b, c) = (Keys::generate().public_key(), Keys::generate().public_key(), Keys::generate().public_key(), Keys::generate().public_key());
        let req = Payload::FriendRequest.body();
        let accept = Payload::FriendResponse(Response::Accepted).body();
        let decline = Payload::FriendResponse(Response::Declined).body();
        let removed = Payload::FriendResponse(Response::Removed).body();
        let rumors = vec![
            // a: we ask, they accept, later they remove us.
            rumor(1, &me, &a, 10, &req),
            rumor(2, &a, &a, 20, &accept),
            // b: they ask, we decline, they ask again.
            rumor(3, &b, &b, 10, &req),
            rumor(4, &me, &b, 11, &decline),
            rumor(5, &b, &b, 30, &req),
            // c: both ask at once: friends.
            rumor(6, &me, &c, 10, &req),
            rumor(7, &c, &c, 12, &req),
        ];
        let f = friendships(&me, &rumors, &HashMap::new());
        assert_eq!(f.get(&a), Some(&Friendship::Accepted));
        assert_eq!(f.get(&b), Some(&Friendship::Incoming));
        assert_eq!(f.get(&c), Some(&Friendship::Accepted));

        let mut later = rumors.clone();
        later.push(rumor(8, &a, &a, 40, &removed));
        assert_eq!(friendships(&me, &later, &HashMap::new()).get(&a), None);

        // Ignoring hides b's request until they ask again.
        let ignored = HashMap::from([(b, 31)]);
        assert_eq!(friendships(&me, &rumors, &ignored).get(&b), None);
        later.push(rumor(9, &b, &b, 50, &req));
        assert_eq!(friendships(&me, &later, &ignored).get(&b), Some(&Friendship::Incoming));
    }

    #[test]
    fn an_answer_in_the_same_second_as_the_request_still_counts() {
        let (me, a) = (Keys::generate().public_key(), Keys::generate().public_key());
        // The accept has the lower id, so a plain (time, id) sort puts it first.
        let rumors = vec![
            rumor(9, &a, &a, 10, &Payload::FriendRequest.body()),
            rumor(1, &me, &a, 10, &Payload::FriendResponse(Response::Accepted).body()),
        ];
        assert_eq!(friendships(&me, &rumors, &HashMap::new()).get(&a), Some(&Friendship::Accepted));
    }

    #[test]
    fn conversation_applies_author_only_edits_deletes_and_reactions() {
        let (me, a) = (Keys::generate().public_key(), Keys::generate().public_key());
        let m1 = EventId::from_slice(&[1; 32]).unwrap();
        let m2 = EventId::from_slice(&[2; 32]).unwrap();
        let rumors = vec![
            rumor(1, &me, &a, 10, "hello"),
            rumor(2, &a, &a, 11, "hey"),
            rumor(3, &a, &a, 12, &Payload::Edit { id: m1, content: "forged".into() }.body()),
            rumor(4, &me, &a, 13, &Payload::Edit { id: m1, content: "hello!".into() }.body()),
            rumor(5, &me, &a, 14, &Payload::Delete { id: m2 }.body()),
            rumor(6, &a, &a, 15, &Payload::Reaction { id: m1, emoji: "🔥".into(), add: true }.body()),
            rumor(7, &me, &a, 16, &Payload::Reaction { id: m1, emoji: "🔥".into(), add: true }.body()),
            rumor(8, &a, &a, 17, &Payload::Reaction { id: m1, emoji: "🔥".into(), add: false }.body()),
            rumor(9, &a, &a, 18, &Payload::FriendRequest.body()),
        ];
        let c = conversation(&rumors);
        assert_eq!(c.len(), 2, "a can't delete my message, and control messages aren't shown");
        assert_eq!(c[0].content, "hello!");
        assert!(c[0].edited);
        assert_eq!(c[0].reactions, vec![("🔥".to_owned(), vec![me])]);

        let mut gone = rumors.clone();
        gone.push(rumor(10, &a, &a, 19, &Payload::Delete { id: m2 }.body()));
        assert_eq!(conversation(&gone).len(), 1);
    }
}
