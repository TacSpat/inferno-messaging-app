# Inferno — Architecture

## Overview

Inferno is a single-binary Rails chat application where all communication flows through Nostr relays. There is no instance-to-instance federation — the relay network is the communication layer. The local SQLite database acts as a cache; Nostr relays are the source of truth.

Users sign up with email and password (Devise). Behind the scenes, Inferno generates a Nostr secp256k1 keypair that serves as their portable identity. Users never need to understand Nostr or manage keys directly.

---

## 1. Identity Model

### Local Identity (Devise)

Devise handles signup, login, email confirmation, and password management. A user's local identifier is `username#discriminator` (e.g. `Tac#0420`).

### Nostr Identity (Keypair)

On signup, the app generates a Nostr secp256k1 keypair:

| Column | Type | Description |
|--------|------|-------------|
| `nostr_public_key` | `string` | 32-byte hex public key (npub) — the user's global identity |
| `nostr_encrypted_private_key` | `text` | Private key encrypted at rest via AES-256-GCM with a key derived from `Rails.application.secret_key_base` |

The public key is the user's identity across the Nostr network. Any Nostr client or Inferno instance with the same keypair is the same person.

### NIP-05 Verification

The app exposes `/.well-known/nostr.json` (NIP-05) mapping local usernames to public keys:

```
GET https://example.com/.well-known/nostr.json?name=tac

{
  "names": {
    "tac": "ab12cd34..."
  }
}
```

This gives every user a human-readable identifier (`tac@example.com`) verifiable by any Nostr client.

---

## 2. Data Architecture

### What's Stored Locally (SQLite)

The local database is a cache of relay data plus app-specific state:

| Data | Description |
|------|-------------|
| User accounts | Devise auth, encrypted Nostr keys, preferences |
| Messages | Cached copies of Kind 9 / Kind 14 events |
| Server structure | Channels, categories, roles — mirrored from relay events (Kinds 31750–31757) |
| Memberships | Server memberships, role assignments |
| Attachments | Active Storage blobs, Blossom URL cache |
| Nostr event log | Deduplication tracking (event IDs already processed) |
| Voice state | LiveKit room/participant state (ephemeral, not relayed) |
| Conversations | DM conversation records and participant lists |

### What Syncs via Nostr Relays

All persistent communication flows through relays. The app publishes and subscribes:

| Event Kind | NIP | Purpose |
|------------|-----|---------|
| Kind 0 | NIP-01 | Profile metadata (name, bio, avatar URL) |
| Kind 7 | NIP-25 | Reactions on messages |
| Kind 9 | NIP-29 | Group chat messages |
| Kind 14 | NIP-24 | Direct messages |
| Kind 1059 | NIP-59 | Gift-wrapped (encrypted) DMs |
| Kind 9005 | NIP-29 | Message deletion events |
| Kind 22242 | NIP-42 | Relay authentication challenges |
| Kind 25050 | — | Typing indicators (ephemeral) |
| Kind 30315 | — | Online presence / status |
| Kind 31750 | — | Server metadata (name, owner, picture, banner) |
| Kind 31751 | — | Server structure (channels, categories, nesting) |
| Kind 31752 | — | Server roles & permissions |
| Kind 31753 | — | Server member presence (join/leave) |
| Kind 31754 | — | Server custom emojis |
| Kind 31755 | — | Server stickers |
| Kind 31756 | — | Server bans |
| Kind 31757 | — | Server invites |

### Data Flow

```
User action (send message, update profile, create channel, etc.)
        │
        ▼
Rails controller / service
        │
        ├── Save to local SQLite (cache)
        │
        ├── Sign as Nostr event (Schnorr/secp256k1)
        │
        └── Publish to all connected relays
                │
                ▼
        Nostr Relay Network
                │
                ▼
        Other subscribers receive event
        (other Inferno instances, Nostr clients, etc.)
```

Inbound events from relays follow the reverse path — the `RelaySubscriptionManager` receives events via WebSocket, validates signatures, deduplicates by event ID, and saves to the local database.

---

## 3. Relay Communication

### Persistent WebSocket Pool

`RelaySubscriptionManager` maintains long-lived WebSocket connections to all configured relays using `Faye::WebSocket` + `EventMachine`. It subscribes to:

- Group messages (Kind 9 filtered by `#h` group ID tags)
- DMs (Kinds 4, 14, 1059 filtered by `#p` recipient and author pubkeys)
- Profile metadata (Kind 0)
- Presence (Kind 30315)
- Typing indicators (Kind 25050, ephemeral)
- Reactions (Kind 7)
- Server state events (Kinds 31750–31757)

### Publishing

`RelayService.publish_to_all()` sends events to all active relays. Uses existing persistent connections when the EventMachine reactor is running; falls back to opening new connections with timeout handling.

### Fetching

`RelayService.fetch_from_all()` parallelizes REQ queries across all relays for history syncs and metadata lookups. Deduplicates by event ID. Waits for EOSE before returning results.

### Relay Authentication (NIP-42)

When a relay requires authentication, the app signs a Kind 22242 challenge-response event with the user's Nostr private key, proving identity without sharing credentials.

---

## 4. Server State Sync

Server state is stored as replaceable Nostr events (Kinds 31750–31757). When a server admin changes channels, roles, members, etc., the app:

1. Updates local SQLite
2. Publishes an updated replaceable event to relays
3. Other instances subscribing to that server's events receive the update

This means server configuration is portable — it lives on relays, not locked in a single database.

### Server State Events

| Kind | d-tag | Content |
|------|-------|---------|
| 31750 | server public ID | Server name, description, icon URL, banner URL, owner pubkey |
| 31751 | server public ID | Channel list with categories, positions, nesting, types |
| 31752 | server public ID | Roles with permissions bitmask, colors, hierarchy |
| 31753 | server public ID + member pubkey | Individual member join/leave, role assignments |
| 31754 | server public ID | Custom emoji definitions with Blossom URLs |
| 31755 | server public ID | Custom sticker definitions with Blossom URLs |
| 31756 | server public ID | Ban list (pubkeys, reasons) |
| 31757 | server public ID | Active invite codes |

---

## 5. Messaging

### Channel Messages (NIP-29)

Messages in channels are published as Kind 9 events with:
- `#h` tag: group/channel identifier
- Content: message text (may include markdown)
- File attachments: encoded as Blossom URLs in the event content/tags
- Replies: `#e` tag referencing parent event ID

For encrypted channels, content is encrypted with NIP-44 (XChaCha20-Poly1305) using the channel's keypair.

### Direct Messages (Kind 14)

DMs use Kind 14 events with `#p` tags for recipients. Content can be:
- Plain text (for non-encrypted conversations)
- NIP-44 encrypted (XChaCha20-Poly1305 with ECDH-derived shared secret)

File attachments in DMs are encoded as JSON payloads with `type: "message"`, containing `content`, `files`, and `emojis` fields.

### Message Rendering

Messages are rendered server-side with:
- Markdown processing (Redcarpet + Rouge for syntax highlighting)
- Custom emoji/sticker substitution
- @mention resolution
- Link preview unfurling (images, YouTube, Tenor GIFs)
- Active Storage file attachment display

---

## 6. Key Management

### Default: Custodial (App-Managed)

The app manages keys for most users:

- Keypair generated on signup using `secp256k1`
- Private key encrypted with AES-256-GCM, key derived from `Rails.application.secret_key_base`
- The user never needs to see or manage their keys
- The app signs Nostr events on the user's behalf

### Key Export (NIP-49)

Power users can export their private key:

- **nsec** — raw private key in bech32 format for use in standalone Nostr clients
- **ncryptsec** — password-encrypted private key (NIP-49) for secure backup

Key export is available in account settings. This is the user's recovery mechanism — if they lose access, an exported key lets them re-establish identity anywhere.

### Key Import

Users can import an existing Nostr keypair:
- Enter an `nsec` or `ncryptsec` to link an existing identity
- NIP-07 browser extension support (nos2x, Alby) for delegated signing

---

## 7. Asset Distribution (Blossom)

File attachments, avatars, banners, and server icons are uploaded to Blossom servers (content-addressable file hosting via BUD-01). URLs are embedded in Nostr events, making assets accessible from any client.

The app caches remote Blossom files locally for performance. Default Blossom servers: `blossom.primal.net`, `cdn.satellite.earth`.

---

## 8. Voice & Video

Voice and video use LiveKit (SFU), not Nostr. This is the only non-relay communication channel:

- Voice channels are local to the LiveKit server
- WebRTC connections go through the LiveKit SFU
- The app generates JWT tokens for LiveKit room access
- Voice state (who's in which channel, mute/deafen) is managed locally

See [voice-video-architecture.md](voice-video-architecture.md) for full details.

---

## 9. Real-Time Broadcasting

Within a single Inferno instance, ActionCable (async adapter) handles real-time WebSocket broadcasting to connected browser clients:

- New messages → broadcast to channel subscribers
- Typing indicators → broadcast to channel
- Presence changes → broadcast to all connected users
- Server state changes → broadcast to server members

ActionCable uses the `async` adapter (in-process, no Redis needed). This is appropriate because Inferno runs as a single process — there's no multi-server deployment to coordinate.

---

## 10. NIPs Reference

| NIP | Title | Usage |
|-----|-------|-------|
| [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) | Basic Protocol | Event format, signing, relay communication |
| [NIP-05](https://github.com/nostr-protocol/nips/blob/master/05.md) | DNS-Based Verification | `user@domain` identifiers via `/.well-known/nostr.json` |
| [NIP-24](https://github.com/nostr-protocol/nips/blob/master/24.md) | Extra Metadata | Kind 14 DM events |
| [NIP-25](https://github.com/nostr-protocol/nips/blob/master/25.md) | Reactions | Kind 7 reactions on messages |
| [NIP-29](https://github.com/nostr-protocol/nips/blob/master/29.md) | Relay-Based Groups | Kind 9 group chat messages, Kind 9005 deletions |
| [NIP-42](https://github.com/nostr-protocol/nips/blob/master/42.md) | Relay Authentication | Kind 22242 challenge-response auth |
| [NIP-44](https://github.com/nostr-protocol/nips/blob/master/44.md) | Encrypted Payloads | XChaCha20-Poly1305 encryption for DMs and private channels |
| [NIP-49](https://github.com/nostr-protocol/nips/blob/master/49.md) | Encrypted Private Key | Password-encrypted key export (ncryptsec) |
| [NIP-59](https://github.com/nostr-protocol/nips/blob/master/59.md) | Gift Wrap | Encrypted DM wrappers (Kind 1059) |

---

## 11. Security

### Cryptographic Protections

| Protection | Mechanism |
|-----------|-----------|
| Event integrity | Schnorr signatures (secp256k1) on all Nostr events |
| DM privacy | NIP-44 XChaCha20-Poly1305 end-to-end encryption |
| Channel privacy | NIP-44 encryption with per-channel keypair |
| Key storage | AES-256-GCM encryption at rest, key derived from `secret_key_base` |
| Relay auth | NIP-42 challenge-response (no passwords over the wire) |
| Transport | HTTPS / WSS for all relay connections |

### Rate Limiting

`Rack::Attack` provides rate limiting on:
- Login attempts (per IP)
- Registration (per IP)
- API endpoints (per user)

---

## 12. Technology Stack

| Layer | Technology |
|-------|-----------|
| Backend | Rails 8.1 |
| Database | SQLite (primary, cache, queue) |
| Background Jobs | Solid Queue |
| Real-time (local) | ActionCable (async adapter) |
| Real-time (relay) | Faye::WebSocket + EventMachine |
| Frontend | Hotwire (Turbo + Stimulus) |
| Styling | Tailwind CSS 4 |
| JS Bundling | Bun (via jsbundling-rails) |
| CSS Bundling | Tailwind (via cssbundling-rails) |
| Asset Pipeline | Propshaft |
| Auth | Devise |
| File Storage | Active Storage + Blossom |
| Voice/Video | LiveKit (SFU) |
| Identity | Nostr (secp256k1 via nostr_ruby) |
| Relay | strfry (C++ Nostr relay) |
| Encryption | NIP-44 (libsodium via Fiddle FFI) |
