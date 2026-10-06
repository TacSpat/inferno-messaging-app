//! Channel traffic: messages, edits, deletions, pins and reactions, on the
//! wire as Rails and Flutter send them (kind 9 with an `h` tag, 9005, 9006,
//! kind 7), plus encrypted-channel keys.
//!
//! Rails and Flutter apply whatever arrives. Here the timeline only counts
//! what the sender was allowed to do:
//! - edits only from the message's author;
//! - deletions from the author or someone with `manage_messages`;
//! - pins only with `manage_messages`;
//! - nothing from banned or blocked users, or sent during a timeout.

pub mod keys;
pub mod send;
pub mod timeline;

pub use keys::ChannelKeys;
pub use timeline::{ChannelMessage, Timeline};
