# Inferno Flutter -- Implementation Roadmap

This document tracks the state of the Inferno Flutter client. It replaces the
earlier Rails-based roadmap. Everything below refers to the Flutter codebase on
the `flutter-rewrite` branch.

---

## Built & Working

### Nostr Identity
- secp256k1 keypair generation
- NIP-49 ncryptsec export
- nsec and ncryptsec import
- Private key stored in platform keychain via flutter_secure_storage
- Key safeguarding: private key never displayed, nsec blocked in outbound
  messages, ncryptsec-only export, no visibility toggle on the import field

### Relay Communication
- RelayPool manages multiple concurrent WebSocket connections
- Publish, subscribe, and close flows
- NIP-42 relay authentication
- Auto-reconnect with exponential backoff

### Server State Sync
- Kinds 31750-31757 replaceable events for server, channels, roles, members,
  bans, invites, emojis, and categories
- ServerSyncService fetches and subscribes to server state
- ServerPublishService writes server mutations back to relays

### Group Chat
- Kind 9 channel messages
- Kind 9005 message deletion
- Kind 7 reactions
- File attachments via Blossom URLs

### Direct Messages
- Kind 14 messages with NIP-44 encryption
- Kind 1059 gift-wrapped delivery
- JSON payload supporting files and custom emoji

### Presence & Typing
- Kind 30315 online/idle/dnd/invisible status with manual status picker
- Kind 25050 typing indicators

### Profile Sync
- Kind 0 metadata events
- Contact list fetching
- Avatar and banner image caching

### Voice & Video
- LiveKit integration via livekit_client
- Voice channels with join/leave
- Mute, deafen, and screen sharing controls
- Kind 10070 public voice-state events (avoids encrypted-DM relay rate limits)

### Asset Distribution
- Blossom BUD-01 upload and retrieval
- cached_network_image for download and local caching

### Message Rendering
- flutter_markdown with custom extensions
- Custom emoji inline rendering
- @-mentions, spoiler tags, fenced code blocks, link previews

### Emoji
- Noto Color Emoji bundled as a fallback font
- Unified picker that merges Unicode emoji with server custom emoji

### Audio Processing
- DeepFilterNet noise suppression via native FFI bridge

### Theme System
- Seven built-in themes
- Hot-swappable behind a spinner overlay (full ThemeData replacement)

### Auto-Updates
- Desktop: GitHub Releases with a self-update shell/batch script
- Mobile: in_app_update (Android) and upgrader (iOS)

### Cross-Platform
- Windows, Linux, macOS, Android, iOS

---

## In Progress

### Content Safety System
- ONNX-based NSFW image detection
- Perceptual image hashing (dHash)
- Reputation scoring per pubkey
- Shared hash network for known-bad content
- Authority-level reporting flow

### Server Settings Overlay
- Server-level admin UI (roles, channels, bans, invites, emoji management)

### Nostr-Based Search
- REQ filter queries against relay indexes for message and user search

---

## Planned

### NIP-46 Remote Signing (Nostr Connect)
Allow users to approve event signatures from a remote signer instead of
storing the private key locally.

### NIP-55 Android Signer Intents (Amber)
Support signing via Android intent to the Amber signer app.

### E2E Encrypted Group Channels
NIP-44 encryption with a per-channel keypair so that relay operators cannot
read channel content.

### Monetization
Stripe payment integration and Lightning Zaps for tipping.

### Server Discovery via Relay Queries
Browse and join public servers by querying relays for Kind 31750 events.

### Hierarchical Voice Channels
Hearths (parent rooms) and embers (sub-rooms) for structured voice.

### Bots & Integrations API
External bot framework that can publish and subscribe to server events.

### Full-Text Message Search
Local SQLite FTS index over cached messages for instant offline search.

### Threads
Threaded replies within channels, displayed as a side panel.

---

## Technical Debt

- **Relay reconnection resilience** -- edge cases around rapid
  disconnect/reconnect cycles and stale subscription state.
- **Inbound event signature verification** -- verify secp256k1 signatures on
  every event received from relays, not just on sync boundaries.
- **Message rendering pipeline consolidation** -- unify the markdown, emoji,
  mention, and spoiler passes into a single composable pipeline.
- **Blossom upload error handling** -- surface per-file errors, retry logic,
  and progress reporting.

---

## Key Libraries

| Library | Purpose |
|---|---|
| flutter_riverpod | State management |
| drift | SQLite ORM with code generation |
| go_router | Declarative routing |
| web_socket_channel | WebSocket transport for relay connections |
| flutter_secure_storage | Platform keychain for private key storage |
| livekit_client | Voice and video via LiveKit SFU |
| cached_network_image | Image download and disk caching |
| flutter_markdown | Markdown rendering |
| pointycastle | Crypto primitives (secp256k1, AES, HMAC) |
| bech32 | Bech32 encoding for npub, nsec, ncryptsec |
| image | Image processing (dHash, resize) |
| media_kit | Audio and video playback |
| file_picker / desktop_drop | File selection and drag-and-drop |
| package_info_plus | App version info for update checks |
