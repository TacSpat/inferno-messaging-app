# Inferno — Implementation Roadmap

Status of each system, organized by what's built, what's in progress, and what's planned.

---

## Built & Working

### Nostr Identity (NIP-01, NIP-05, NIP-49)

- Secp256k1 keypair generated on signup via `nostr_ruby`
- Private key encrypted at rest (AES-256-GCM, key derived from `secret_key_base`)
- `/.well-known/nostr.json` endpoint (NIP-05) maps usernames to pubkeys
- Key export: raw `nsec` and password-encrypted `ncryptsec` (NIP-49) in account settings
- Key import: accept `nsec` or connect via NIP-07 browser extension

### Relay Communication

- `RelaySubscriptionManager` — persistent WebSocket pool to all configured relays (Faye::WebSocket + EventMachine)
- `RelayService.publish_to_all()` — fire-and-forget event publishing to all relays
- `RelayService.fetch_from_all()` — parallel REQ queries with deduplication and EOSE handling
- NIP-42 relay authentication (Kind 22242 challenge-response)
- `NostrEventLog` deduplication — tracks processed event IDs to prevent duplicates

### Server State Sync (Kinds 31750–31757)

- `NostrServerSyncService` — publishes and fetches server configuration via replaceable events
- Kind 31750: server metadata (name, description, icon, banner, owner)
- Kind 31751: channel structure (categories, nesting, positions, types)
- Kind 31752: roles & permissions
- Kind 31753: member join/leave and role assignments
- Kind 31754: custom emojis (with Blossom URLs)
- Kind 31755: custom stickers (with Blossom URLs)
- Kind 31756: bans
- Kind 31757: invites

### Group Chat (NIP-29)

- Kind 9 events for channel messages with `#h` group ID tag
- Kind 9005 for message deletion
- Kind 7 for reactions
- Encrypted channels via NIP-44 (XChaCha20-Poly1305 with per-channel keypair)
- File attachments encoded as Blossom URLs in event content/tags
- Message editing via `#e` tags referencing original events

### Direct Messages (Kind 14)

- Kind 14 events with `#p` recipient tags
- NIP-44 encryption (XChaCha20-Poly1305, ECDH shared secret)
- Kind 1059 gift-wrapped DMs (NIP-59)
- JSON payload format for messages with file attachments and custom emoji
- DM pagination (scroll-up loading)
- History sync via `NostrHistoryFetcher`

### Presence & Typing

- Kind 30315 for online status broadcasting (online, idle, dnd, invisible)
- Kind 25050 for typing indicators (ephemeral)
- Manual status picker (Online / Idle / Do Not Disturb / Invisible) with localStorage persistence
- Idle detection with automatic status transitions (respects manual DnD/Invisible)

### Profile Sync (Kind 0)

- Profile metadata published as Kind 0 events (name, bio, avatar URL, NIP-05)
- Remote member profiles fetched from relays and cached locally
- Avatar/banner caching from Blossom URLs

### Voice & Video (LiveKit)

- LiveKit SFU integration for voice channels
- Screen sharing with system audio
- Moderation: server mute, server deafen, move between channels
- Per-channel settings: bitrate, user limits, video toggle
- Hierarchical channel nesting
- JWT-based room access tokens

### Asset Distribution (Blossom)

- `BlossomClientService` uploads to content-addressable Blossom servers (BUD-01)
- Default servers: `blossom.primal.net`, `cdn.satellite.earth`
- Remote file caching for locally-stored copies
- Configurable Blossom server URLs

### Admin & Safety

- Server settings: usage limits (max channels, roles, members, etc.)
- Lockdown mode: pause signups
- User suspensions
- Audit logging
- Data exports
- Message retention (time-based pruning, pinned message exemption)

---

## In Progress

### Remote Member Support

- `RemoteMember` model tracks users from other Nostr clients/instances by pubkey
- Profile fetching from relays (Kind 0)
- Role assignment within servers
- Presence display for remote members

---

## Planned

### Native Apps

- **Mobile (iOS + Android)** — Turbo Native wrapping the responsive web UI
- **Desktop** — Tauri app wrapping the web UI
- Native push notifications

### E2E Encrypted DMs

- Client-side NIP-44 encryption in the Stimulus controller
- Server stores only ciphertext — zero-knowledge
- Gradual rollout: unencrypted DMs remain functional during transition

### Monetization

- **Stripe** for card payments, **Bitcoin Lightning / Zaps** (NIP-57) for crypto-native users
- Cosmetic purchases: animated avatars, profile effects, badges, premium sticker packs
- Verification badge: small one-time payment, proof of personhood
- Tipping: direct user-to-user via Zaps or Stripe

### Content Safety

- Upload scanning pipeline: SHA-256 + perceptual hash (dHash) on image uploads
- Known-bad hash database (NCMEC, Project VIC)
- Auto-quarantine, auto-suspend on match
- NCMEC CyberTipline reporting integration

### Search

- Full-text message search across channels and DMs

### Bots & Integrations

- Webhook endpoints
- Bot accounts
- Custom slash commands

---

## Technical Debt / Cleanup

- [ ] Consolidate message rendering pipeline (markdown + emoji + unfurl)
- [ ] Improve relay reconnection resilience (exponential backoff, health checks)
- [ ] Add relay event signature verification on all inbound events
- [ ] Improve Blossom upload error handling and retry logic

---

## Library Summary

| Gem/Library | Purpose |
|-------------|---------|
| `nostr_ruby` | Key generation, event creation/signing, signature verification |
| `faye-websocket` | WebSocket client for relay connections (via EventMachine) |
| `rack-attack` | HTTP rate limiting |
| `fiddle` | FFI bindings to libsodium for NIP-44 encryption |
| `livekit-server-sdk` | LiveKit room/token management |
| `jwt` | JWT generation for LiveKit access tokens |
| `redcarpet` | Markdown rendering |
| `rouge` | Syntax highlighting in code blocks |
| `image_processing` | Image transformation for Active Storage variants |
