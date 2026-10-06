//! Inferno client core. Holds everything that isn't UI so it can sit under
//! Makepad, or under Flutter / Tauri if the UI spike fails the gate.

pub mod channel;
pub mod dm;
pub mod dtag;
pub mod keys;
pub mod kinds;
pub mod relay;
pub mod search;
pub mod social;
pub mod server;
pub mod session;
pub mod store;
pub mod sync;
pub mod vault;

pub use nostr;
pub use nostr_sdk;
