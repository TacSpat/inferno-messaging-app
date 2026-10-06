//! Custom Nostr kinds both existing apps already speak. Keep them stable so the
//! Rust client stays wire-compatible with Rails and Flutter.

// Server state (parameterized replaceable).
pub const SERVER_METADATA: u16 = 31750;
pub const SERVER_STRUCTURE: u16 = 31751;
pub const SERVER_ROLES: u16 = 31752;
pub const SERVER_MEMBER: u16 = 31753;
pub const SERVER_EMOJI: u16 = 31754;
pub const SERVER_STICKERS: u16 = 31755;
pub const SERVER_BAN: u16 = 31756;
pub const SERVER_INVITE: u16 = 31757;

// Live signals.
pub const VOICE_STATE: u16 = 10070;
pub const TYPING: u16 = 25050;
/// Custom reuse of NIP-29's 9006 for pins.
pub const PIN: u16 = 9006;
pub const PRESENCE: u16 = 30315;

/// Cross-device config (NIP-78 app data).
pub const APP_CONFIG: u16 = 30078;
