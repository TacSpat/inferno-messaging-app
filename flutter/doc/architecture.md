# Inferno Flutter -- Architecture Document

## Overview

Inferno is a standalone desktop and mobile messaging application built with Flutter. It has no server component. The app connects directly to Nostr relays over WebSocket to send, receive, and synchronize all data. Identity is a secp256k1 keypair; there are no accounts, emails, or passwords. The local SQLite database is a cache -- relays are the source of truth.

**Platforms:** Windows, Linux, macOS, Android, iOS

---

## Technology Stack

| Layer | Technology |
|---|---|
| Framework | Flutter (Dart) |
| State management | Riverpod (StateNotifier, FutureProvider, StreamProvider) |
| Routing | go_router with ShellRoute for persistent layout |
| Database / ORM | Drift (SQLite) with code generation via build_runner |
| WebSocket | Pure Dart (`web_socket_channel`) |
| Cryptography | Pure Dart secp256k1 Schnorr signatures, NIP-44 XChaCha20-Poly1305, NIP-49 scrypt |
| Secure storage | flutter_secure_storage (platform keychain) |
| Voice/Video | LiveKit via `livekit_client` |
| Audio processing | DeepFilterNet noise suppression via native FFI |
| Content safety | ONNX Runtime via FFI for on-device NSFW classification |
| File hosting | Blossom servers (BUD-01 protocol) |
| Image caching | cached_network_image |
| Markdown | flutter_markdown with custom builders |
| Emoji | Bundled Noto Color Emoji font for cross-platform consistency |

---

## Identity

Inferno uses Nostr keypairs for identity. There is no email/password authentication, no OAuth, no Devise, and no server-side session.

**Authentication flow:**

1. On first launch, the user either generates a new keypair or imports an existing one (nsec or ncryptsec).
2. The private key is stored in the platform keychain via `flutter_secure_storage`.
3. On subsequent launches, `AuthService` checks for a stored keypair. If one exists, the user is authenticated. If not, they are routed to the login/signup screen.
4. The public key (hex) serves as the user's unique identifier across the Nostr network.

**What "auth" means in Inferno:** Auth is simply "does the platform keychain contain a stored keypair?" There is no token exchange, no session cookie, no server validation.

`AuthService` (`lib/services/auth_service.dart`) exposes `privateKeyHex` and `publicKeyHex` after loading from secure storage. These are passed to services that need to sign or decrypt events.

---

## Key Management

`KeyManagementService` (`lib/services/key_management_service.dart`) handles all keypair operations:

| Operation | Method | Details |
|---|---|---|
| Generate | `generateAndStore()` | Creates a new secp256k1 keypair, stores both keys in platform keychain |
| Load | `load()` | Reads private key from keychain, derives full `NostrKey` |
| Import nsec | `importNsec(nsec)` | Decodes bech32 nsec to hex, stores in keychain |
| Import ncryptsec | `importNcryptsec(ncryptsec, password)` | NIP-49 scrypt decryption, stores result in keychain |
| Export ncryptsec | `exportNcryptsec(password)` | NIP-49 scrypt encryption of stored private key |
| Export npub | `exportNpub()` | Bech32-encodes the public key |

**Security rules:**

- The raw private key (nsec) is never displayed to the user and never exported in plaintext.
- Export is ncryptsec only (NIP-49 encrypted with a user-chosen password).
- The private key never leaves `flutter_secure_storage` except into memory for signing/decryption operations.

**Cryptography modules** (`lib/crypto/`):

| File | Purpose |
|---|---|
| `nostr_key.dart` | Keypair generation and derivation |
| `nostr_signer.dart` | Schnorr signing (secp256k1) |
| `nostr_verifier.dart` | Signature verification |
| `nostr_event.dart` | Nostr event model (kind, tags, content, serialization) |
| `nip44_crypto.dart` | NIP-44 XChaCha20-Poly1305 encryption/decryption for DMs |
| `nip49_crypto.dart` | NIP-49 scrypt-based key encryption/decryption |
| `bech32_nostr.dart` | Bech32 encoding/decoding (npub, nsec, ncryptsec) |

---

## Data Architecture

### SQLite via Drift

The local database is a cache. All authoritative data lives on Nostr relays. If the database is deleted, the app re-fetches everything from relays on next launch.

**Database definition:** `lib/database/database.dart` -- `InfernoDatabase` class annotated with `@DriftDatabase`, listing all tables and DAOs. Generated code lives in `database.g.dart`.

**Tables** (`lib/database/tables/`):

| Table | Purpose |
|---|---|
| `users` | User profiles (local and remote) |
| `servers` | Joined servers with Nostr group IDs |
| `channels` | Text and voice channels within servers |
| `categories` | Channel grouping/ordering |
| `messages` | All messages (DMs, group chat, channel messages) |
| `conversations` | DM conversation metadata |
| `conversation_participants` | DM conversation members |
| `contacts` | Friend/contact relationships |
| `roles` | Server roles with permission bitmasks |
| `server_memberships` | User-server membership records |
| `membership_roles` | Role assignments per member |
| `remote_members` | Relay-sourced member data (before local user resolution) |
| `remote_membership_roles` | Relay-sourced role assignments |
| `invites` | Server invite links/codes |
| `bans` | Server bans |
| `blocks` | User-level blocks |
| `reactions` | Message reactions |
| `channel_reads` | Per-channel read position tracking |
| `notifications` | Notification records |
| `server_emojis` | Custom server emoji |
| `server_stickers` | Custom server stickers |
| `server_folders` | Server folder organization |
| `voice_states` | Voice channel participation state |
| `calls` | Call metadata |
| `call_participants` | Call participant records |
| `nostr_event_logs` | Processed event deduplication log |
| `nostr_events` | Raw Nostr event cache |
| `relay_connections` | Relay URL and connection config |
| `server_voice_providers` | LiveKit voice provider configuration per server |
| `app_settings` | Local app preferences |
| `content_hashes` | Perceptual/cryptographic hashes for content safety |
| `gif_collections` | GIF search result caching |
| `gif_favorites` | User's favorited GIFs |
| `media_cache` | Media dimension/metadata cache |
| `csam_hash_entries` | CSAM hash database entries |
| `hidden_attachment_records` | Attachments hidden by content safety |

**DAOs** (`lib/database/daos/`): `MessagesDao`, `ServersDao`, `ContactsDao` -- encapsulate complex queries.

### Data flow

**Outbound (user action):**

```
User action
  -> Service method
    -> Build NostrEvent
      -> Sign with NostrSigner (Schnorr)
        -> Publish to RelayPool
          -> Save to local Drift DB
```

**Inbound (relay event):**

```
RelayPool receives JSON from WebSocket
  -> Parse to NostrEvent (background isolate for batches)
    -> Deduplicate (check _processedEventIds set + nostr_event_logs table)
      -> Route by kind via onKind handler
        -> Service processes event
          -> Upsert into Drift DB
            -> Riverpod providers react to DB changes -> UI updates
```

---

## Relay Communication

### RelayConnection (`lib/nostr/relay_connection.dart`)

A single WebSocket connection to one Nostr relay. Handles:

- Connect/disconnect lifecycle
- Automatic reconnection with backoff
- Sending raw JSON frames
- Receiving and parsing relay messages (`EVENT`, `EOSE`, `OK`, `AUTH`, `NOTICE`)

### RelayPool (`lib/nostr/relay_pool.dart`)

Manages multiple `RelayConnection` instances. Core capabilities:

| Feature | Details |
|---|---|
| Multi-relay fan-out | Publishes events to all connected relays |
| Kind-based routing | `onKind(int kind, EventHandler)` registers handlers per event kind |
| Global handlers | Catch-all event handlers for cross-cutting concerns |
| Subscription management | `subscribe()` sends REQ to all relays, tracks by subscription ID |
| EOSE handling | Per-subscription EOSE callbacks for knowing when historical data is complete |
| Publish tracking | `OK` response completers -- publish returns a Future<bool> indicating relay acceptance |
| Deduplication | In-memory set of processed event IDs prevents double-processing |
| NIP-42 auth | `authPrivateKeyHex`/`authPublicKeyHex` for relay authentication challenges |
| Background parsing | Uses `compute()` to parse event JSON on background isolates |
| Failure tracking | Per-relay failure counters; skips relays after 3 consecutive failures in fetchFresh |
| fetchFresh | Opens throwaway WebSocket connections for one-shot queries with NIP-42 support |

### Supporting modules (`lib/nostr/`):

| File | Purpose |
|---|---|
| `nostr_filter.dart` | Builds Nostr filter objects (kinds, authors, tags, since, until, limit) |
| `subscription.dart` | Subscription model (ID, filters, handlers) |
| `relay_auth.dart` | NIP-42 authentication event construction and signing |
| `event_dispatcher.dart` | Event routing and dispatch logic |

---

## Server State Sync

Servers in Inferno are represented as a set of replaceable Nostr events (Kinds 31750-31757). Each event kind represents a different aspect of server state.

### Replaceable event kinds

| Kind | Purpose | d-tag format |
|---|---|---|
| 31750 | Server metadata (name, icon, description, settings) | `{server_public_id}` |
| 31751 | Server structure (channels, categories, ordering) | `{server_public_id}` |
| 31752 | Roles (permissions, colors, ordering) | `{server_public_id}` |
| 31753 | Members | `{server_public_id}:{member_pubkey}` |
| 31754 | Custom emoji | `{server_public_id}` |
| 31755 | Custom stickers | `{server_public_id}` |
| 31756 | Bans | `{server_public_id}` |
| 31757 | Invites | `{server_public_id}` |

### ServerSyncService (`lib/services/server_sync_service.dart`)

Responsible for fetching and processing server state from relays.

**Sync sequence** (mirrors the Rails `NostrServerJoinJob`):

1. Fetch metadata (Kind 31750) -- server name, icon, description, AFK channel, voice providers
2. Fetch structure (Kind 31751) -- channels, categories, ordering
3. Fetch roles (Kind 31752) -- role definitions, permissions, hierarchy
4. Fetch members (Kind 31753) -- per-member events with role assignments
5. Fetch emoji (Kind 31754) -- custom server emoji
6. Fetch stickers (Kind 31755) -- custom sticker packs
7. Fetch bans (Kind 31756) -- banned users
8. Subscribe to channel messages for all text channels

**Throttling:** By default, sync is skipped if the server was synced within the last 5 minutes (`minInterval` parameter). Periodic resync runs every 60 minutes.

**Preloaded events:** Discovery results can be passed as `preloadedStructure`, `preloadedRoles`, `preloadedMetadata` to avoid redundant relay fetches when joining a new server.

### ServerPublishService (`lib/services/server_publish_service.dart`)

Publishes server state changes as signed replaceable events to the relay pool. Each mutation (rename server, add channel, update role, etc.) rebuilds the relevant Kind 3175x event with the full current state and publishes it.

---

## Messaging

### Group Messages (Kind 9, NIP-29)

Handled by `GroupMessageService` (`lib/services/group_message_service.dart`).

- Messages are published as Kind 9 events with an `h` tag containing the server's Nostr group ID.
- Inbound Kind 9 events are matched to servers by `h` tag, resolved to a channel, and upserted into the messages table.
- File attachments are URLs in the content (uploaded to Blossom servers first).

### Direct Messages (Kind 14, NIP-24 / Kind 1059, NIP-59)

Handled by `DmService` (`lib/services/dm_service.dart`).

- Outbound: Content is encrypted with NIP-44 (XChaCha20-Poly1305) using the shared secret between sender and recipient. The encrypted payload is wrapped in a Kind 14 event, then gift-wrapped in a Kind 1059 event.
- Inbound: Kind 1059 gift wraps are decrypted with the user's private key, revealing the Kind 14 inner event. The inner content is decrypted with NIP-44.
- DMs also carry voice token responses and voice state updates as structured JSON payloads.

### Message Deletion (Kind 9005)

Deletion events reference the original event ID. Services process these by marking messages as deleted in the local DB.

### Reactions (Kind 7)

Handled by `ReactionService` (`lib/services/reaction_service.dart`). Reactions reference the target event via `e` tag. Custom emoji reactions use the emoji shortcode as content.

### Typing Indicators (Kind 25050, ephemeral)

Handled by `TypingService` (`lib/services/typing_service.dart`). Ephemeral events -- not persisted to relays, only forwarded to connected clients. Published when the user is actively typing in a channel or DM.

### Message Rendering

`MessageContent` and `MessageBubble` widgets (`lib/widgets/`) render messages using `flutter_markdown` with custom builders for:

- `@mentions` -- resolved to display names with tap-to-profile
- Custom emoji -- rendered inline from server emoji URLs
- Code blocks -- syntax-highlighted
- Spoiler tags -- hidden until tapped
- Link embeds -- preview cards for URLs (`lib/widgets/link_embed.dart`)
- File attachments -- images, videos, audio with appropriate previews

---

## Bootstrap Sequence

`AppBootstrapService` (`lib/services/app_bootstrap_service.dart`) orchestrates startup:

1. **Warm media cache** -- single SELECT to preload image dimension data for instant layout
2. **Ensure default relays** -- seed relay list if first run
3. **Ensure local user** -- create a user record for the current keypair if missing
4. **Connect to relays** -- parallel connection to all active relay URLs (3-second timeout)
5. **Set auth credentials** -- configure NIP-42 credentials on the relay pool
6. **Register event handlers** -- wire up `onKind` callbacks for all relevant event kinds
7. **Publish presence** -- start periodic Kind 30315 presence publishing
8. **Set up subscriptions** -- subscribe to DMs, profiles, presence, typing, reactions, server events
9. **Start periodic resync** -- 60-minute timer to re-fetch all server state
10. **Initialize NSFW detector** -- load ONNX model (non-blocking, falls back gracefully)
11. **Start shared hash service** -- fetch content safety hash lists

---

## State Management (Riverpod)

Providers live in `lib/providers/`:

| Provider | Type | Purpose |
|---|---|---|
| `databaseProvider` | Provider | Singleton `InfernoDatabase` instance |
| `authProvider` | StateNotifierProvider | Auth state (keypair loaded, public key, login/logout) |
| `serversProvider` | StateNotifierProvider | Server list, active server, join/leave |
| `conversationsProvider` | StateNotifierProvider | DM conversation list and metadata |
| `realtimeProvider` | Provider | Holds `AppBootstrapService` -- the live relay connection and all event handlers |
| `serverSettingsProvider` | StateNotifierProvider | Server settings editing state |
| `unreadProvider` | StateNotifierProvider | Unread message counts per channel/conversation |
| `appUpdateProvider` | FutureProvider | Checks GitHub Releases API for available updates |

Services are instantiated inside providers to ensure single instances are shared between UI and background event processing.

---

## Routing

`go_router` (`lib/router.dart`) with a `ShellRoute` for the persistent three-column layout:

```
/auth/login          -- Login screen
/auth/signup         -- Signup (generate keypair)
/auth/import         -- Import existing key (nsec/ncryptsec)
/auth/setup          -- Profile setup wizard

/conversations       -- DM list (ShellRoute child)
/conversations/:id   -- DM detail

/servers/:serverId/channels/:channelId  -- Text channel
/servers/:serverId/voice/:channelId     -- Voice channel
```

The `MainShell` widget wraps all post-auth routes, providing:

- **Left rail:** Server icon list (`ServerRail`)
- **Sidebar:** Channel list (`ChannelSidebar`) or DM list (`DmSidebar`)
- **Content area:** The routed child widget
- **Right panel:** Member list (`MemberList`), togglable

Page transitions are disabled (`CustomTransitionPage` with `Duration.zero`) -- content swaps instantly, matching Discord-style navigation.

---

## Voice and Video

### Architecture

Voice and video use LiveKit, a WebRTC-based media server. The Inferno app does not run its own media server -- it connects to LiveKit instances configured per server.

### Components

| Component | Location | Purpose |
|---|---|---|
| `LivekitService` | `lib/services/livekit_service.dart` | Room connection, track management, participant state |
| `VoiceTokenService` | `lib/services/voice_token_service.dart` | JWT token generation for LiveKit auth |
| `VoiceStateService` | `lib/services/voice_state_service.dart` | Publishes/subscribes Kind 10070 voice state events |
| `CallService` | `lib/services/call_service.dart` | Call initiation and lifecycle |
| `VoiceChannelScreen` | `lib/screens/voice/voice_channel_screen.dart` | Voice channel UI |
| `VoiceControls` | `lib/widgets/voice_controls.dart` | Mute, deafen, disconnect controls |
| `ParticipantTile` | `lib/widgets/participant_tile.dart` | Individual participant video/audio tile |

### Voice state (Kind 10070)

Voice presence is published as Kind 10070 public events so all server members can see who is in which voice channel without being connected themselves. These events contain:

- Channel identifier
- Mute/deafen state
- Server identifier

### Audio processing

DeepFilterNet noise suppression is available on desktop platforms via native FFI:

- Native library: `native/deepfilter/`
- Dart bindings: `lib/src/deepfilter_bindings.dart`
- Processing: `lib/services/noise_processor.dart`

The noise suppression model runs on-device. If the native library is unavailable, the app falls back to unprocessed audio.

---

## Assets and File Hosting

### Blossom (BUD-01)

`BlossomClient` (`lib/services/blossom_client.dart`) handles file uploads to Blossom servers.

**Upload flow:**

1. Compute SHA-256 hash of file bytes
2. Build a Kind 24242 authorization event (signed, with expiration)
3. HTTP PUT to the Blossom server's `/upload` endpoint with the auth header
4. Server returns the file URL

**Default servers:** `blossom.primal.net`, `cdn.satellite.earth`

### Caching

- `MediaCacheService` (`lib/services/media_cache_service.dart`) -- caches image dimensions to prevent layout reflow
- `BlossomCacheService` (`lib/services/blossom_cache_service.dart`) -- manages local file cache
- `AssetCacheService` (`lib/services/asset_cache_service.dart`) -- general asset caching
- `cached_network_image` -- HTTP-level image caching with disk persistence

---

## Content Safety

### NSFW Detection

`NsfwDetector` (`lib/services/nsfw_detector.dart`) runs a two-stage image classification pipeline on-device using ONNX Runtime via FFI:

- Native library: `native/onnxruntime/`
- Dart bindings: `lib/src/onnxruntime_bindings.dart`

Images are classified locally. Detected NSFW content is blurred with a click-to-reveal overlay. No images are sent to external services for classification.

### Content Safety Service

`ContentSafetyService` (`lib/services/content_safety_service.dart`) orchestrates safety checks on messages, combining:

- NSFW image detection
- Perceptual hash matching against known-bad content (`SharedHashService`)
- CSAM hash database lookups

### Image Hashing

`ImageHasher` (`lib/services/image_hasher.dart`) computes perceptual hashes for content matching. `SharedHashService` (`lib/services/shared_hash_service.dart`) fetches and maintains shared hash lists from relays.

---

## Theme System

Seven bundled themes, all dark, defined in `lib/theme/all_themes.dart`:

| Theme | Accent |
|---|---|
| Inferno | Red (#DC2626) |
| Frostfire | Blue (#2563EB) |
| Boron | Green (#059669) |
| Brimstone | Purple (#7C3AED) |
| Plasma | Pink (#DB2777) |
| Pulsar | Amber (#F59E0B) |
| Obsidian | Gray (#9CA3AF) |

Each theme is built from a parameterized `_buildTheme()` function that takes primary colors and a gray scale (gray50 through gray950). The result is a full `ThemeData` with consistent `ColorScheme`, `AppBarTheme`, `CardTheme`, `InputDecorationTheme`, and text styles.

Theme switching is hot-swappable. `ThemeProvider` (`lib/theme/theme_provider.dart`) swaps the entire `ThemeData` behind a spinner overlay to prevent partial-render flicker. The active theme preference is persisted in the `app_settings` table.

All text rendering uses a font family stack with `NotoColorEmoji` as a fallback to ensure emoji render identically across Windows, Linux, macOS, Android, and iOS.

---

## Auto-Updates

`AppUpdateService` (`lib/services/app_update_service.dart`) checks the GitHub Releases API every 30 minutes on desktop platforms. When a newer version is detected, an `UpdateBanner` widget is shown. The user can download and install the update.

Mobile platforms (Android, iOS) use their respective app store update mechanisms.

---

## Nostr Implementation Protocol (NIP) Reference

| NIP | Purpose | Implementation |
|---|---|---|
| NIP-01 | Basic protocol (events, filters, subscriptions) | `lib/nostr/relay_pool.dart`, `lib/crypto/nostr_event.dart` |
| NIP-02 | Contact list | `ContactService` |
| NIP-10 | Event threading (reply tags) | `GroupMessageService` message parsing |
| NIP-19 | Bech32 encoding (npub, nsec, ncryptsec) | `lib/crypto/bech32_nostr.dart` |
| NIP-24 | Sealed DMs (Kind 14) | `DmService` |
| NIP-25 | Reactions (Kind 7) | `ReactionService` |
| NIP-29 | Group chat (Kind 9) | `GroupMessageService` |
| NIP-42 | Relay authentication (Kind 22242) | `lib/nostr/relay_auth.dart` |
| NIP-44 | Encrypted payloads (XChaCha20-Poly1305) | `lib/crypto/nip44_crypto.dart` |
| NIP-49 | Key encryption (ncryptsec) | `lib/crypto/nip49_crypto.dart` |
| NIP-59 | Gift wrap (Kind 1059) | `DmService` |

### Custom event kinds

| Kind | Purpose |
|---|---|
| 10070 | Voice channel state (public, replaceable) |
| 24242 | Blossom upload authorization |
| 25050 | Typing indicators (ephemeral) |
| 30315 | Presence/status (replaceable) |
| 31750 | Server metadata (parameterized replaceable) |
| 31751 | Server structure |
| 31752 | Server roles |
| 31753 | Server members |
| 31754 | Server emoji |
| 31755 | Server stickers |
| 31756 | Server bans |
| 31757 | Server invites |

---

## Security Model

### Threat model

Inferno is a client-only application. There is no Inferno server to compromise. The attack surface is:

1. **Relay operators** -- can see public events, withhold events, or serve stale data. Mitigation: multi-relay fan-out, local cache, event signature verification.
2. **Local device compromise** -- private key in platform keychain. Mitigation: OS-level keychain protection (Keychain on macOS/iOS, Keystore on Android, libsecret on Linux, Credential Manager on Windows).
3. **Network interception** -- all relay connections use WSS (WebSocket over TLS).

### Cryptographic guarantees

- **Authentication:** Every event is signed with Schnorr (secp256k1). Signature is verified on receipt.
- **DM confidentiality:** NIP-44 XChaCha20-Poly1305 with HKDF-derived shared secrets. Only sender and recipient can decrypt.
- **Key export:** NIP-49 scrypt encryption. Private key never leaves the device in plaintext.
- **No trust in relays:** Relays are untrusted storage. Events are self-authenticating via signatures. Tampered events fail verification and are discarded.

### Content safety

- On-device NSFW classification (no external API calls)
- Perceptual hash matching against shared databases
- CSAM hash checking
- All processing happens locally -- no images are uploaded to classification services

---

## Directory Structure

```
lib/
  main.dart                 -- Entry point
  app.dart                  -- MaterialApp with Riverpod, router, theme
  router.dart               -- go_router route definitions

  crypto/                   -- Pure Dart cryptography
    nostr_key.dart           -- Keypair generation/derivation
    nostr_signer.dart        -- Schnorr signing
    nostr_verifier.dart      -- Signature verification
    nostr_event.dart         -- Event model and serialization
    nip44_crypto.dart        -- NIP-44 encryption
    nip49_crypto.dart        -- NIP-49 key encryption
    bech32_nostr.dart        -- Bech32 encoding/decoding

  database/                 -- Drift ORM layer
    database.dart            -- Database class definition
    database.g.dart          -- Generated code
    tables/                  -- Table definitions (37 tables)
    daos/                    -- Data access objects

  nostr/                    -- Relay communication
    relay_connection.dart    -- Single WebSocket connection
    relay_pool.dart          -- Multi-relay pool manager
    nostr_filter.dart        -- Subscription filter builder
    subscription.dart        -- Subscription model
    relay_auth.dart          -- NIP-42 authentication
    event_dispatcher.dart    -- Event routing

  providers/                -- Riverpod state management
    database_provider.dart
    auth_provider.dart
    servers_provider.dart
    conversations_provider.dart
    realtime_provider.dart
    server_settings_provider.dart
    unread_provider.dart
    app_update_provider.dart

  services/                 -- Business logic (40+ services)
    app_bootstrap_service.dart
    auth_service.dart
    key_management_service.dart
    dm_service.dart
    group_message_service.dart
    server_sync_service.dart
    server_publish_service.dart
    contact_service.dart
    reaction_service.dart
    presence_service.dart
    typing_service.dart
    backfill_service.dart
    relay_config_service.dart
    livekit_service.dart
    voice_token_service.dart
    voice_state_service.dart
    blossom_client.dart
    content_safety_service.dart
    nsfw_detector.dart
    noise_processor.dart
    ... (and others)

  screens/                  -- Full-screen UI
    auth/                    -- Login, signup, key import, setup wizard
    channels/                -- Text channel, channel type router, search panel
    conversations/           -- DM list, DM detail
    voice/                   -- Voice channel
    settings/                -- Settings hub, appearance, notifications, safety, voice/video
    server_settings/         -- Server settings overlay
    main_shell.dart          -- Persistent three-column layout shell

  widgets/                  -- Reusable UI components
    server_rail.dart         -- Server icon sidebar
    channel_sidebar.dart     -- Channel list
    dm_sidebar.dart          -- DM conversation list
    member_list.dart         -- Server member list
    message_list.dart        -- Scrollable message list
    message_bubble.dart      -- Individual message rendering
    message_content.dart     -- Markdown content rendering
    message_input.dart       -- Compose bar with file upload
    typing_indicator.dart    -- Typing status display
    reaction_bar.dart        -- Reaction display and picker
    unified_picker.dart      -- Emoji/GIF/sticker picker
    voice_controls.dart      -- Voice channel controls
    ... (and others)

  theme/                    -- Theme system
    all_themes.dart          -- 7 theme definitions
    inferno_theme.dart       -- Legacy/fallback theme constants
    theme_provider.dart      -- Hot-swap theme management
    ui_effects.dart          -- Visual effect utilities

  models/                   -- Domain models
    permission.dart          -- Permission bitmask model

  src/                      -- FFI bindings
    deepfilter_bindings.dart -- DeepFilterNet noise suppression
    onnxruntime_bindings.dart -- ONNX Runtime for NSFW detection

  utils/                    -- Utility functions

native/                     -- Native C/C++ libraries
  deepfilter/               -- DeepFilterNet noise suppression
  onnxruntime/              -- ONNX Runtime for inference
```
