//! Cross-device sync for one identity.

pub mod config;
pub mod profile;
pub mod relays;

use nostr_sdk::prelude::*;

/// A replaceable event must be dated after every copy already out there:
/// relays keep the newest, and on a same-second tie the lower id wins.
pub(crate) fn publish_time(newest_seen: Option<Timestamp>) -> Timestamp {
    let now = Timestamp::now();
    match newest_seen {
        Some(seen) if seen >= now => Timestamp::from(seen.as_secs() + 1),
        _ => now,
    }
}
