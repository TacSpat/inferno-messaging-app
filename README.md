# Inferno

**Blazing fast. Hot to the touch.**

Inferno is a chat app that looks and feels like the platforms you already know — servers, channels, voice chat, roles, DMs, all of it — but with one difference: nobody can take it away from you.

Centralized platforms can change their terms whenever they want — require ID verification, harvest your data, ban your community, or shut down entirely. You have no say and no recourse. Inferno exists because your community shouldn't be at the mercy of someone else's policy decisions.

There is no server component. No backend. No account database. Inferno is a standalone native app that connects directly to Nostr relays. Your identity is a cryptographic keypair generated on your device. Your messages, servers, profiles, and relationships all live on relays you choose. The local SQLite database is a cache — delete it and everything rebuilds from the network.

## Features

- **Messaging** — text channels, direct messages, file sharing, reactions, custom emoji/stickers, GIF search, link previews, @mentions, markdown rendering
- **Voice & Video** — voice channels, screen sharing, mute/deafen, noise suppression (DeepFilterNet), moderation controls (LiveKit)
- **Servers** — organize channels into categories, invite links, custom icons, channel reordering, nested channels
- **Roles** — fine-grained permissions (30+), role hierarchy, per-channel overrides, role editor
- **Social** — friend requests, blocking, user profile cards, online/idle/DnD/invisible status, typing indicators
- **Identity** — Nostr secp256k1 keypair generated on signup, NIP-05 verification, key export (NIP-49 ncryptsec only), portable across any Nostr client
- **Relay-Bound** — all server state, messages, DMs, and profiles sync through Nostr relays — no direct peer-to-peer or client-to-server communication
- **Encrypted DMs** — NIP-44 (XChaCha20-Poly1305) encryption, pure Dart implementation
- **Key Security** — private keys stored in platform keychain via flutter_secure_storage, never displayed in the UI, export only via NIP-49 encrypted format
- **File Hosting** — Blossom servers for content-addressable file storage (BUD-01)
- **Content Safety** — on-device NSFW detection via ONNX Runtime (native FFI), no cloud API calls
- **Cross-Platform** — native on Windows, Linux, macOS, Android, iOS
- **Auto-Updates** — GitHub Releases for desktop, app stores for mobile

## Stack

Flutter (Dart) / Drift (SQLite) / Riverpod / GoRouter / LiveKit / Nostr (NIP-01, NIP-05, NIP-17, NIP-29, NIP-42, NIP-44, NIP-49) / DeepFilterNet (FFI) / ONNX Runtime (FFI) / Blossom (BUD-01)

## How It Works

```
+---------------------+
|    Inferno App       |
|  (Flutter / Dart)    |
|                      |
|  +---------------+   |          +------------------+
|  | Drift SQLite  |   |  NIP-01  |   Nostr Relays   |
|  | (local cache) |   | <------> | wss://relay1.com |
|  +---------------+   |  NIP-29  | wss://relay2.com |
|                      |  NIP-44  | wss://relay3.com |
|  +---------------+   |          +------------------+
|  | Secure Store  |   |
|  | (keychain)    |   |          +------------------+
|  +---------------+   |  BUD-01  |  Blossom Servers |
|                      | <------> | (file storage)   |
|  +---------------+   |          +------------------+
|  | Native FFI    |   |
|  | - DeepFilter  |   |          +------------------+
|  | - ONNX RT     |   |  SFU     |  LiveKit Server  |
|  +---------------+   | <------> | (voice/video)    |
+---------------------+          +------------------+
```

There is no application server. The Flutter app holds your private key and talks directly to Nostr relays over WebSocket. All events are signed client-side with your secp256k1 key before publishing. Relay connections are managed by a connection pool with automatic reconnection, subscription deduplication, and NIP-42 authentication.

**Data flow:**

1. You create a server. Inferno publishes NIP-29 group metadata events to your chosen relay.
2. You send a message. Inferno signs a kind-9 event and publishes it. Other members' clients receive it in real time via their relay subscriptions.
3. You send a DM. Inferno encrypts it with NIP-44, publishes a kind-1059 gift-wrapped event. Only the recipient can decrypt it.
4. You upload a file. Inferno hashes it, uploads to a Blossom server, and includes the URL in the message event.
5. You join a voice channel. Inferno requests a LiveKit token from the server relay, then connects to the LiveKit SFU directly.

**Local storage is a cache.** Drift (SQLite) stores messages, profiles, and server state locally for fast access. On first launch or after clearing data, the app backfills from relays. The relay is the source of truth.

## Nostr Protocol Usage

| NIP | Purpose |
|------|---------|
| NIP-01 | Basic event structure, relay communication, subscriptions |
| NIP-05 | DNS-based identity verification (user@domain.com) |
| NIP-17 | Private direct messages (gift-wrapped) |
| NIP-29 | Relay-based groups (servers, channels, roles, membership) |
| NIP-42 | Relay authentication (AUTH challenge-response) |
| NIP-44 | Encryption (XChaCha20-Poly1305 for DMs and private channels) |
| NIP-49 | Key export (ncryptsec encrypted private key format) |

## Project Structure

```
lib/
  nostr/             # Relay connections, subscriptions, event dispatch, auth
  providers/         # Riverpod providers (realtime, server settings, theme)
  screens/
    auth/            # Login, signup, key import, setup wizard
    channels/        # Text channels, channel routing, search
    conversations/   # DM list, conversation detail
    server_settings/ # Roles, members, bans, server config
    settings/        # Account, profile, appearance, relays, key export, safety
    voice/           # Voice channels, calls
  services/          # Business logic (40+ services)
  src/               # Native FFI bindings (DeepFilterNet, ONNX Runtime)
  theme/             # Theme data, UI effects
  utils/             # URL utilities
  widgets/           # Reusable UI components (30+ widgets)
native/
  deepfilter/        # DeepFilterNet native library source
  onnxruntime/       # ONNX Runtime native library source
assets/
  icons/             # App icons
  fonts/             # Bundled Noto Color Emoji
  models/            # ONNX models (NSFW classifier)
```

## Setup

### Prerequisites

- Flutter SDK 3.11+ (Dart 3.11+)
- Platform build tools:
  - **Linux**: `clang`, `cmake`, `ninja-build`, `pkg-config`, `libgtk-3-dev`, `libmpv-dev`
  - **macOS**: Xcode 15+
  - **Windows**: Visual Studio 2022 with C++ desktop workload
  - **Android**: Android Studio, SDK 21+
  - **iOS**: Xcode 15+, CocoaPods

### Build and Run

```bash
# Clone
git clone https://github.com/nickkjolsing/inferno.git
cd inferno/flutter

# Get dependencies
flutter pub get

# Generate Drift database and Freezed models
dart run build_runner build --delete-conflicting-outputs

# Run (desktop)
flutter run -d linux
flutter run -d macos
flutter run -d windows

# Run (mobile)
flutter run -d android
flutter run -d ios
```

### Native Libraries

DeepFilterNet (noise suppression) and ONNX Runtime (NSFW detection) are built via Dart's native assets hook system during `flutter build`. The build hook in `hook/` compiles the native libraries automatically. No manual steps required.

### Release Builds

```bash
flutter build linux --release
flutter build macos --release
flutter build windows --release
flutter build apk --release
flutter build ios --release
```

Desktop releases are distributed via GitHub Releases with auto-update support. Mobile releases go through their respective app stores.

## Key Management

Inferno generates a Nostr secp256k1 keypair on signup. The private key is stored in the platform's secure keychain (Keychain on macOS/iOS, Keystore on Android, libsecret on Linux, Windows Credential Manager on Windows) via `flutter_secure_storage`. The key is never displayed in the UI.

To move your identity to another device or client, use the key export screen in Settings. Keys are exported exclusively in NIP-49 `ncryptsec` format — encrypted with a passphrase you choose. There is no plaintext nsec export.

To import an existing Nostr identity, use the key import screen at login. Inferno accepts both `nsec` (plaintext) and `ncryptsec` (encrypted) formats.

## License

Elastic License 2.0 — see [LICENSE](LICENSE) for details.
