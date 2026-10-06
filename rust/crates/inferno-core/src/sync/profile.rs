//! Kind 0 profile updates. Kind 0 is replaceable, so whatever we publish
//! replaces the whole profile. Updates therefore start from the newest
//! published copy and change only the fields asked for; fields we don't know
//! about (other clients, other NIPs) pass through untouched.
//!
//! Flutter did this too, but merged onto whichever relay answered first,
//! which could be a stale copy; here it's the newest across all relays and
//! the local cache.

use nostr_sdk::prelude::*;
use serde_json::{Map, Value};

use crate::relay::RelayPool;
use crate::store::{Store, StoreError};

#[derive(Debug, thiserror::Error)]
pub enum ProfileError {
    #[error(transparent)]
    Store(#[from] StoreError),
    #[error(transparent)]
    Relay(#[from] nostr_sdk::prelude::Error),
    #[error("could not sign the profile: {0}")]
    Build(String),
    #[error("no relay accepted the profile")]
    NotPublished,
}

/// Per field: `None` leaves it as published, `Some(None)` clears it,
/// `Some(Some(v))` sets it. Keys match what Rails and Flutter publish.
#[derive(Debug, Default, Clone)]
pub struct ProfileUpdate {
    pub name: Option<Option<String>>,
    pub display_name: Option<Option<String>>,
    pub about: Option<Option<String>>,
    pub picture: Option<Option<String>>,
    pub banner: Option<Option<String>>,
    pub nip05: Option<Option<String>>,
    pub status: Option<Option<String>>,
    pub status_emoji: Option<Option<String>>,
    /// Rails' two profile colors (`#rrggbb`); not standard kind 0 fields,
    /// so other clients ignore them, but Inferno members see them.
    pub profile_color: Option<Option<String>>,
    pub profile_color_2: Option<Option<String>>,
}

impl ProfileUpdate {
    pub fn apply(&self, profile: &mut Map<String, Value>) {
        let fields = [
            ("name", &self.name),
            ("display_name", &self.display_name),
            ("about", &self.about),
            ("picture", &self.picture),
            ("banner", &self.banner),
            ("nip05", &self.nip05),
            ("status", &self.status),
            ("status_emoji", &self.status_emoji),
            ("profile_color", &self.profile_color),
            ("profile_color_2", &self.profile_color_2),
        ];
        for (key, change) in fields {
            match change {
                None => {}
                Some(None) => {
                    profile.remove(key);
                }
                Some(Some(v)) if v.is_empty() => {
                    profile.remove(key);
                }
                Some(Some(v)) => {
                    profile.insert(key.to_owned(), Value::String(v.clone()));
                }
            }
        }
    }
}

/// Content of a kind 0, or an empty object if it isn't a JSON object.
pub fn content(event: &Event) -> Map<String, Value> {
    match serde_json::from_str(&event.content) {
        Ok(Value::Object(map)) => map,
        _ => Map::new(),
    }
}

/// Publishes `update` on top of the newest known profile and caches it.
pub async fn update(
    pool: &RelayPool,
    store: &Store,
    keys: &Keys,
    update: &ProfileUpdate,
) -> Result<Event, ProfileError> {
    let me = keys.public_key();
    let fetched = pool.fetch(vec![Filter::new().kind(Kind::Metadata).author(me)]).await?;
    for event in &fetched {
        store.put_event(event)?;
    }
    // The store keeps only the newest copy, local or fetched.
    let base = store.get_addressable(Kind::Metadata, &me, "")?;

    let mut profile = base.as_ref().map(content).unwrap_or_default();
    update.apply(&mut profile);
    let event = EventBuilder::new(Kind::Metadata, Value::Object(profile).to_string())
        .custom_created_at(super::publish_time(base.map(|e| e.created_at)))
        .finalize(keys)
        .map_err(|e| ProfileError::Build(e.to_string()))?;

    if !pool.publish(&event).await?.any_accepted() {
        return Err(ProfileError::NotPublished);
    }
    store.put_event(&event)?;
    Ok(event)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn untouched_and_unknown_fields_survive() {
        let mut profile = json!({
            "name": "tac", "nip05": "tac@inferno.example", "lud16": "tac@wallet.example"
        })
        .as_object()
        .unwrap()
        .clone();
        ProfileUpdate {
            about: Some(Some("hi".into())),
            display_name: Some(Some("Tac".into())),
            ..Default::default()
        }
        .apply(&mut profile);
        assert_eq!(profile["nip05"], "tac@inferno.example");
        assert_eq!(profile["lud16"], "tac@wallet.example");
        assert_eq!(profile["about"], "hi");

        ProfileUpdate { about: Some(None), nip05: Some(Some(String::new())), ..Default::default() }
            .apply(&mut profile);
        assert!(!profile.contains_key("about"));
        assert!(!profile.contains_key("nip05"), "empty string clears, like Flutter");
    }

    #[tokio::test]
    async fn merges_onto_the_newest_copy_across_relays() {
        let fresh = MockRelay::run().await.unwrap();
        let stale = MockRelay::run().await.unwrap();
        let keys = Keys::generate();

        let profile_at = |at: u64, body: Value| {
            EventBuilder::new(Kind::Metadata, body.to_string())
                .custom_created_at(Timestamp::from(at))
                .finalize(&keys)
                .unwrap()
        };
        // Seed each relay separately: one has the newer profile with nip05.
        for (relay, event) in [
            (&fresh, profile_at(200, json!({ "name": "tac", "nip05": "tac@x.example" }))),
            (&stale, profile_at(100, json!({ "name": "old" }))),
        ] {
            let seed = RelayPool::new(keys.clone());
            seed.add_relays([relay.url().await.to_string()]).await.unwrap();
            seed.connect().await;
            seed.publish(&event).await.unwrap();
        }

        let pool = RelayPool::new(keys.clone());
        pool.add_relays([stale.url().await.to_string(), fresh.url().await.to_string()]).await.unwrap();
        pool.connect().await;
        let store = Store::open_in_memory().unwrap();

        let published = update(&pool, &store, &keys, &ProfileUpdate {
            about: Some(Some("new bio".into())),
            ..Default::default()
        })
        .await
        .unwrap();
        let body = content(&published);
        assert_eq!(body["name"], "tac");
        assert_eq!(body["nip05"], "tac@x.example");
        assert_eq!(body["about"], "new bio");
        assert!(published.created_at.as_secs() > 200);
    }
}

/// A kind 0 body as the member-event profile Rails embeds in 31753.
pub fn member_profile(profile: &Map<String, Value>) -> crate::server::wire::MemberProfile {
    let s = |k: &str| profile.get(k).and_then(Value::as_str).unwrap_or_default().to_owned();
    let o = |k: &str| Some(s(k)).filter(|v| !v.is_empty());
    crate::server::wire::MemberProfile {
        name: s("name"),
        display_name: s("display_name"),
        about: s("about"),
        picture: o("picture"),
        banner: o("banner"),
        color: o("profile_color"),
        color_2: o("profile_color_2"),
        status: s("status"),
        status_emoji: s("status_emoji"),
    }
}
