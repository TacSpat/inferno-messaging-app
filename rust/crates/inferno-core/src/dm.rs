//! Direct messages. New messages go out as NIP-17: an unsigned kind 14 rumor,
//! sealed in kind 13, gift-wrapped in kind 1059 — one wrap for the recipient
//! and one for ourselves so our other devices see what we sent.
//!
//! Rails and Flutter both sign kind 14 directly with a NIP-44 encrypted body.
//! We only ever send NIP-17, but still read that legacy form during the
//! migration window.
//!
//! The body is the same in both forms, so everything above this layer is
//! unchanged: plain text, or JSON with a `type` (`message`, `reaction`,
//! `friend_request`, `friend_response`, and the voice/RPC control messages).

use nostr::nips::nip44;
use nostr::nips::nip59::{GiftWrapBuilder, UnwrappedGift};
use nostr_sdk::prelude::*;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Wire {
    Nip17,
    Legacy,
}

#[derive(Debug, Clone)]
pub struct IncomingDm {
    pub sender: PublicKey,
    /// Who the message is addressed to (its `p` tag). Equals our own key for
    /// messages sent to us; another key for our own sends echoed back.
    pub recipient: Option<PublicKey>,
    /// The rumor id (NIP-17) or event id (legacy). Stable across the
    /// recipient's and the sender's copy, so use it to dedupe.
    pub id: EventId,
    pub created_at: Timestamp,
    pub tags: Tags,
    pub body: String,
    pub wire: Wire,
}

#[derive(Debug, thiserror::Error)]
pub enum DmError {
    #[error("not a DM event")]
    NotADm,
    #[error("could not decrypt: {0}")]
    Decrypt(String),
    #[error("could not build the event: {0}")]
    Build(String),
    #[error("seal signer does not match the rumor author")]
    ForgedSender,
}

/// Builds the events to publish for one DM. `extra_tags` (e.g. NIP-30 emoji)
/// go on the rumor, inside the encryption.
pub fn build(
    keys: &Keys,
    recipient: PublicKey,
    body: &str,
    extra_tags: Vec<Tag>,
) -> Result<Vec<Event>, DmError> {
    let mut tags = vec![Tag::public_key(recipient)];
    tags.extend(extra_tags);

    let mut rumor = EventBuilder::new(Kind::PrivateDirectMessage, body)
        .tags(tags)
        .finalize_unsigned(keys.public_key());
    rumor.ensure_id();

    let wrap = |to: PublicKey| {
        GiftWrapBuilder::new(to, rumor.clone())
            .finalize(keys)
            .map_err(|e| DmError::Build(e.to_string()))
    };
    let mut events = vec![wrap(recipient)?];
    if recipient != keys.public_key() {
        events.push(wrap(keys.public_key())?);
    }
    Ok(events)
}

/// Opens a kind 1059 gift wrap or a legacy kind 14 addressed to or from us.
pub fn open(keys: &Keys, event: &Event) -> Result<IncomingDm, DmError> {
    match event.kind {
        Kind::GiftWrap => open_gift_wrap(keys, event),
        Kind::PrivateDirectMessage => open_legacy(keys, event),
        _ => Err(DmError::NotADm),
    }
}

fn open_gift_wrap(keys: &Keys, event: &Event) -> Result<IncomingDm, DmError> {
    let UnwrappedGift { sender, mut rumor } =
        UnwrappedGift::from_gift_wrap(keys, event).map_err(|e| DmError::Decrypt(e.to_string()))?;
    // NIP-17: the seal's signer must be the rumor's author, or anyone could
    // wrap a rumor claiming to be from someone else.
    if rumor.pubkey != sender {
        return Err(DmError::ForgedSender);
    }
    if rumor.kind != Kind::PrivateDirectMessage {
        return Err(DmError::NotADm);
    }
    let recipient = rumor.tags.public_keys().next();
    let id = rumor.id();
    Ok(IncomingDm {
        sender,
        recipient,
        id,
        created_at: rumor.created_at,
        tags: rumor.tags.clone(),
        body: rumor.content,
        wire: Wire::Nip17,
    })
}

fn open_legacy(keys: &Keys, event: &Event) -> Result<IncomingDm, DmError> {
    let recipient = event.tags.public_keys().next();
    // Our own sends come back from relays too; decrypt those with the
    // recipient's key as the counterparty.
    let counterparty = if event.pubkey == keys.public_key() {
        recipient.ok_or(DmError::NotADm)?
    } else {
        event.pubkey
    };
    let body = nip44::decrypt(keys.secret_key(), &counterparty, &event.content)
        .map_err(|e| DmError::Decrypt(e.to_string()))?;
    Ok(IncomingDm {
        sender: event.pubkey,
        recipient,
        id: event.id,
        created_at: event.created_at,
        tags: event.tags.clone(),
        body,
        wire: Wire::Legacy,
    })
}

/// Filters for everything DM-shaped addressed to us. Gift wraps carry a
/// randomized `created_at` up to two days in the past, so a `since` on them
/// must be pushed back by that much or recent messages are missed.
pub fn filters(me: PublicKey, since: Option<Timestamp>) -> Vec<Filter> {
    const WRAP_JITTER_SECS: u64 = 2 * 24 * 60 * 60;
    let mut wraps = Filter::new().kind(Kind::GiftWrap).pubkey(me);
    let mut legacy_in = Filter::new().kind(Kind::PrivateDirectMessage).pubkey(me);
    let mut legacy_out = Filter::new().kind(Kind::PrivateDirectMessage).author(me);
    if let Some(since) = since {
        wraps = wraps.since(Timestamp::from(since.as_secs().saturating_sub(WRAP_JITTER_SECS)));
        legacy_in = legacy_in.since(since);
        legacy_out = legacy_out.since(since);
    }
    vec![wraps, legacy_in, legacy_out]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nip17_round_trip_for_recipient_and_our_other_devices() {
        let alice = Keys::generate();
        let bob = Keys::generate();
        let events = build(&alice, bob.public_key(), "hi bob", vec![]).unwrap();
        assert_eq!(events.len(), 2);
        assert!(events.iter().all(|e| e.kind == Kind::GiftWrap));
        // The wrap is signed by a throwaway key, never by Alice.
        assert!(events.iter().all(|e| e.pubkey != alice.public_key()));

        let for_bob = open(&bob, &events[0]).unwrap();
        assert_eq!(for_bob.sender, alice.public_key());
        assert_eq!(for_bob.recipient, Some(bob.public_key()));
        assert_eq!(for_bob.body, "hi bob");
        assert_eq!(for_bob.wire, Wire::Nip17);

        let for_alice = open(&alice, &events[1]).unwrap();
        assert_eq!(for_alice.id, for_bob.id, "both copies dedupe to one message");
        assert!(open(&bob, &events[1]).is_err(), "Bob can't open Alice's copy");
    }

    /// What Rails and Flutter send: kind 14 signed by the sender, NIP-44 body.
    fn legacy_dm(from: &Keys, to: PublicKey, body: &str) -> Event {
        let content = nip44::encrypt(from.secret_key(), &to, body, nip44::Version::V2).unwrap();
        EventBuilder::new(Kind::PrivateDirectMessage, content)
            .tag(Tag::public_key(to))
            .finalize(from)
            .unwrap()
    }

    #[test]
    fn reads_legacy_dms_both_directions() {
        let alice = Keys::generate();
        let bob = Keys::generate();
        let legacy = &legacy_dm(
            &alice,
            bob.public_key(),
            r#"{"type":"reaction","action":"add","e":"x","emoji":"🔥"}"#,
        );

        let at_bob = open(&bob, legacy).unwrap();
        assert_eq!(at_bob.wire, Wire::Legacy);
        assert!(at_bob.body.contains("reaction"));
        let echoed = open(&alice, legacy).unwrap();
        assert_eq!(echoed.body, at_bob.body);
    }

    #[test]
    fn rejects_a_rumor_whose_author_is_not_the_sealer() {
        let mallory = Keys::generate();
        let alice = Keys::generate();
        let bob = Keys::generate();
        let mut forged = EventBuilder::new(Kind::PrivateDirectMessage, "from alice, honest")
            .tag(Tag::public_key(bob.public_key()))
            .finalize_unsigned(alice.public_key());
        forged.ensure_id();
        let wrap = GiftWrapBuilder::new(bob.public_key(), forged).finalize(&mallory).unwrap();
        // nostr's unwrap already refuses this ("sender mismatch"); our own
        // check stays as a second line in case that ever changes.
        assert!(matches!(
            open(&bob, &wrap),
            Err(DmError::ForgedSender | DmError::Decrypt(_))
        ));
    }
}
