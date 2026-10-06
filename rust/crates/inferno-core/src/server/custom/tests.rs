use serde_json::json;

use super::*;

const GID: &str = "inferno-abc123";

struct W {
    owner: Keys,
    manager: Keys,
    creator: Keys,
    member: Keys,
    events: Vec<Event>,
    clock: u64,
}

fn s(parts: &[&str]) -> Vec<String> {
    parts.iter().map(|p| p.to_string()).collect()
}

impl W {
    fn new() -> Self {
        let mut w = W {
            owner: Keys::generate(),
            manager: Keys::generate(),
            creator: Keys::generate(),
            member: Keys::generate(),
            events: vec![],
            clock: 1_000,
        };
        let manage = json!({ "manage_emojis": true }).to_string();
        let create = json!({ "create_emojis": true, "create_stickers": true }).to_string();
        let everyone = json!({ "send_messages": true }).to_string();
        let roles = w.signed(&w.owner.clone(), kinds::SERVER_ROLES, vec![
            s(&["d", &dtag::roles(GID)]), s(&["server", GID]),
            s(&["role", "r-manage", "Emoji Mgr", "#f0f", "3", "false", "false", &manage, ""]),
            s(&["role", "r-create", "Artist", "#0ff", "2", "false", "false", &create, ""]),
            s(&["role", "r-everyone", "@everyone", "#99aab5", "0", "false", "false", &everyone, ""]),
        ]);
        w.events.push(roles);
        for (who, role) in [(w.manager.clone(), Some("r-manage")), (w.creator.clone(), Some("r-create")), (w.member.clone(), None)] {
            let pk = who.public_key().to_hex();
            let mut tags = vec![s(&["d", &dtag::member(GID, &pk)]), s(&["server", GID]), s(&["p", &pk])];
            if let Some(r) = role {
                tags.push(s(&["roles", r]));
            }
            let owner = w.owner.clone();
            let e = w.signed(&owner, kinds::SERVER_MEMBER, tags);
            w.events.push(e);
        }
        w
    }

    fn signed(&mut self, who: &Keys, kind: u16, tags: Vec<Vec<String>>) -> Event {
        self.clock += 1;
        EventBuilder::new(Kind::Custom(kind), "")
            .tags(tags.into_iter().map(|t| Tag::parse(t).unwrap()))
            .custom_created_at(Timestamp::from(self.clock))
            .finalize(who)
            .unwrap()
    }

    fn state(&self) -> ServerState {
        ServerState::resolve(GID, self.owner.public_key(), &self.events)
    }

    /// Publishes a builder's event, re-dated so it's strictly newer.
    fn publish(&mut self, e: Event) {
        self.clock += 1;
        let redated = EventBuilder::new(e.kind, e.content.clone())
            .tags(e.tags.clone())
            .custom_created_at(Timestamp::from(self.clock));
        let signer = [&self.owner, &self.manager, &self.creator, &self.member]
            .into_iter()
            .find(|k| k.public_key() == e.pubkey)
            .unwrap()
            .clone();
        self.events.push(redated.finalize(&signer).unwrap());
    }

    fn emoji_names(&self) -> Vec<String> {
        let mut v: Vec<_> = self.state().emojis.iter().map(|e| e.name.clone()).collect();
        v.sort();
        v
    }
}

const URL: &str = "https://blossom.example/x.png";

#[test]
fn managers_and_creators_add_members_cannot() {
    let mut w = W::new();
    let state = w.state();
    assert_eq!(add_emoji(&w.member, &state, "nope", URL), Err(CustomError::NotAllowed));
    w.publish(add_emoji(&w.manager, &state, "blaze", URL).unwrap());
    let state = w.state();
    w.publish(add_emoji(&w.creator, &state, "spark", URL).unwrap());
    assert_eq!(w.emoji_names(), ["blaze", "spark"]);
    let spark = w.state().emojis.into_iter().find(|e| e.name == "spark").unwrap();
    assert_eq!(spark.creator, Some(w.creator.public_key()));
}

#[test]
fn a_creator_cannot_remove_or_rewrite_others_items() {
    let mut w = W::new();
    w.publish(add_emoji(&w.manager, &w.state(), "blaze", URL).unwrap());
    // The creator's client publishes a list without "blaze" and with a
    // forged item credited to the manager.
    let creator = w.creator.clone();
    let forged_tags = vec![
        s(&["d", &dtag::emojis(GID)]), s(&["server", GID]),
        s(&["emoji", "mine", URL, &creator.public_key().to_hex()]),
        s(&["emoji", "framed", URL, &w.manager.public_key().to_hex()]),
    ];
    let e = w.signed(&creator, kinds::SERVER_EMOJI, forged_tags);
    w.events.push(e);
    assert_eq!(w.emoji_names(), ["blaze", "mine"]);
    assert_eq!(remove_emoji(&w.creator, &w.state(), "blaze"), Err(CustomError::NotAllowed));
}

#[test]
fn a_managers_removal_sticks_and_keeps_everyone_elses() {
    let mut w = W::new();
    w.publish(add_emoji(&w.manager, &w.state(), "blaze", URL).unwrap());
    w.publish(add_emoji(&w.creator, &w.state(), "spark", URL).unwrap());
    w.publish(add_emoji(&w.creator, &w.state(), "ember", URL).unwrap());
    w.publish(remove_emoji(&w.manager, &w.state(), "spark").unwrap());
    assert_eq!(w.emoji_names(), ["blaze", "ember"], "removal sticks; the creator's other item survives");
    assert_eq!(remove_emoji(&w.manager, &w.state(), "spark"), Err(CustomError::NotFound("spark".into())));
}

#[test]
fn validation_matches_rails() {
    let w = W::new();
    let state = w.state();
    for bad in ["", "Caps", "has space", "dash-ed", &"x".repeat(33)] {
        assert_eq!(add_emoji(&w.manager, &state, bad, URL), Err(CustomError::BadEmojiName), "{bad:?}");
    }
    assert_eq!(add_emoji(&w.manager, &state, "ok", "http://insecure.example/x.png"), Err(CustomError::BadUrl));
    assert_eq!(add_sticker(&w.manager, &state, "  ", "", URL), Err(CustomError::BadStickerName));
}

#[test]
fn names_are_unique_and_limits_hold() {
    let mut w = W::new();
    w.publish(add_emoji(&w.manager, &w.state(), "blaze", URL).unwrap());
    assert_eq!(add_emoji(&w.creator, &w.state(), "blaze", URL), Err(CustomError::NameTaken("blaze".into())));

    w.publish(add_sticker(&w.creator, &w.state(), "Wave", "hi", URL).unwrap());
    assert_eq!(
        add_sticker(&w.manager, &w.state(), "wave", "", URL),
        Err(CustomError::NameTaken("wave".into())),
        "sticker names are case-insensitive"
    );

    for i in 1..MAX_EMOJIS {
        w.publish(add_emoji(&w.manager, &w.state(), &format!("e{i}"), URL).unwrap());
    }
    assert_eq!(w.state().emojis.len(), MAX_EMOJIS);
    assert_eq!(add_emoji(&w.manager, &w.state(), "onemore", URL), Err(CustomError::LimitReached(MAX_EMOJIS)));
}

#[test]
fn stickers_round_trip_in_rails_format() {
    let mut w = W::new();
    let e = add_sticker(&w.creator, &w.state(), "Wave", "says hi", URL).unwrap();
    let row = e.tags.iter().map(|t| t.as_slice().to_vec()).find(|t| t[0] == "sticker").unwrap();
    assert_eq!(row, s(&["sticker", "Wave", "says hi", URL, &w.creator.public_key().to_hex()]));
    w.publish(e);
    assert_eq!(w.state().stickers[0].description, "says hi");
    w.publish(remove_sticker(&w.manager, &w.state(), "WAVE").unwrap());
    assert!(w.state().stickers.is_empty());
}

#[test]
fn message_emoji_tags_cover_used_server_emoji_once() {
    let mut w = W::new();
    w.publish(add_emoji(&w.manager, &w.state(), "blaze", URL).unwrap());
    w.publish(add_emoji(&w.manager, &w.state(), "ember", "https://blossom.example/e.png").unwrap());
    let state = w.state();
    let tags = emoji_tags(&state, "at 12:30 :blaze: then :unknown: :blaze::ember: done");
    assert_eq!(tags, vec![("blaze".into(), URL.into()), ("ember".into(), "https://blossom.example/e.png".into())]);
}
