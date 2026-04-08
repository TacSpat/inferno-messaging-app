# Voice & Video Channels -- Architecture

## Overview

This document describes the architecture for Discord-style voice and video channels in the Inferno Chat Flutter client. Voice channels use the `channel_type: voice` (value `1`) enum. This design covers SFU selection, Drift database schema, Nostr-based voice state, client-side WebRTC via `livekit_client`, native audio processing via DeepFilterNet, moderation flows, and phased implementation.

The guiding principle is **standalone client, no server dependency**: the Flutter app generates LiveKit tokens locally, publishes voice state as Nostr events (Kind 10070), and communicates with a voice provider via encrypted DMs. There is no Rails backend, no ActionCable, and no server-side webhook handling.

---

## 1. Requirements

| User Requirement | Technical Capability | Where It Lives |
|---|---|---|
| Move users between voice channels | SFU move-participant API | Not yet implemented (requires provider-side support) |
| Mute an individual member | Kind 10070 Nostr event from moderator | `_publishVoiceState()` in `voice_channel_screen.dart` |
| Server-wide mute (e.g. stage mode) | SFU room-level permissions via token grants | `VoiceTokenService.generateToken()` with `canPublish: false` |
| Self-mute / self-deafen | Client-side track disable | `LiveKitService.toggleMicrophone()` / `toggleDeafen()` |
| Permission checks for voice actions | Permission enum in Dart | `Permission` enum in `lib/models/permission.dart` |
| Screen share with optional audio | SFU screen share track | `LiveKitService.toggleScreenShare()` via `livekit_client` |
| See who is in what call | Kind 10070 Nostr events with `#h` tag | Published to relays, subscribed by all server members |

---

## 2. WebRTC Topology Primer

Three topologies exist for multi-party WebRTC:

```
Mesh (P2P)                  SFU                         MCU

A <--> B               A --> +-----+ --> B        A --> +-----+ --> A
| \  / |               |     | SFU |     |         |     | MCU |     |
|  \/  |               |     |     |     |         |     | Mix |     |
|  /\  |               |     |     |     |         |     |     |     |
| /  \ |               |     +-----+     |         |     +-----+     |
C <--> D               C -->         --> D        C -->           --> D

N*(N-1)/2 connections   N connections (up)          N connections
each peer encodes       1 encode per peer           1 encode per peer
N-1 times               server forwards             server mixes into
                        selectively                  single stream
```

**Why SFU:**

- **Mesh** fails beyond ~4 users -- each peer must encode and upload N-1 streams, saturating residential upload bandwidth. Acceptable only for 1:1 calls.
- **MCU** is server-expensive -- it decodes every stream, mixes them into a single composite, and re-encodes. CPU cost scales with participant count. No modern chat platform uses this.
- **SFU** is the sweet spot: each peer sends one upload, the server forwards selectively without transcoding. CPU cost is low (routing, not encoding). This is what Discord, Slack, Teams, and Meet all use.

---

## 3. SFU Options Comparison

### Full Comparison

| Criteria | LiveKit | Janus | mediasoup | Galene | Jitsi |
|---|---|---|---|---|---|
| Language | Go | C | Node + C++ | Go | Java + JS |
| License | Apache 2.0 | GPLv3 | ISC | MIT | Apache 2.0 |
| Dart SDK | **Yes** (`livekit_client` on pub.dev) | No | No | No | No |
| Self-host complexity | Docker one-liner / single binary | Complex (deps, plugin config) | Node sidecar + custom signaling | Single binary | Very complex (multiple services) |
| Built-in TURN | Yes (integrated) | No (needs coturn) | No (needs coturn) | No (needs coturn) | Yes (built-in) |
| Server-side mute/kick | Native API | Plugin-dependent | Custom implementation | No API | REST API |
| Move participant | Native API | No | No | No | Partial |
| Recording | Built-in (Egress) | Plugin | No | No | Jibri (separate service) |
| Simulcast | Yes | Yes | Yes | Yes | Yes |
| RAM idle | ~30 MB | ~10 MB | ~40 MB | ~15 MB | ~500 MB+ |
| GitHub stars | 20k+ | 8k+ | 6k+ | 1k+ | 22k+ |
| Project age | ~4 years | 10+ years | ~7 years | ~4 years | 15+ years |

### LiveKit

Modern Go-based SFU built for exactly this use case. The only option with a first-party Dart/Flutter SDK (`livekit_client`), meaning room connection, track management, and participant events integrate directly into Flutter widgets. Built-in TURN eliminates the need for a separate coturn deployment. Single binary or Docker image, ~30 MB RAM idle.

**Pros:** Dart SDK, batteries-included (TURN, recording), excellent docs, active development, Apache 2.0.
**Cons:** Youngest project on this list, though 4 years and 20k+ stars indicate strong adoption.

### Janus

Battle-tested C-based media server, extremely mature. Very low memory footprint (~10 MB). Plugin architecture is flexible but means more integration work -- there is no Dart SDK and no webhook system.

**Pros:** Proven at scale, minimal RAM, GPLv3 is fine for self-hosted deployments.
**Cons:** No Dart SDK, no webhooks, complex deployment, plugin system requires C knowledge for customization.

### mediasoup

Node.js signaling layer with C++ media workers. Highly flexible -- you build your own signaling server. This is more of a library than a turnkey solution.

**Pros:** ISC license, very flexible, strong community.
**Cons:** Requires a Node.js sidecar process, no Dart SDK, no built-in TURN/moderation, significant custom code needed.

### Galene

Lightweight Go-based SFU designed for videoconferencing. Single binary, very low footprint. However, it has no server-side moderation API and a much smaller community.

**Pros:** MIT license, tiny footprint, simple deployment.
**Cons:** No Dart SDK, no moderation API, small community, limited feature set for a chat platform.

### Jitsi

The most feature-complete open-source video platform. Full-featured out of the box with recording, transcription, and more. However, it is an entire application stack (Java + JS + multiple services), not an embeddable component. Deployment is complex and resource-heavy (~500 MB+ RAM idle).

**Pros:** Apache 2.0, extremely feature-rich, huge community, built-in TURN.
**Cons:** Very complex deployment (5+ services), no Dart SDK, heavy resource usage, designed as a standalone app rather than an embeddable SFU.

---

## 4. Recommendation: LiveKit

Three-tier reasoning:

### Integration

LiveKit is the **only SFU with a first-party Dart/Flutter SDK** (`livekit_client`). Room connection, track management, participant events, and screen sharing are native Dart API calls. Token generation uses `dart_jsonwebtoken` locally -- no server round-trip needed for self-hosted providers. The Flutter client is fully standalone.

### Features

Every moderation requirement maps to either a local action or a Nostr event:

- **Self-mute** -- `LiveKitService.toggleMicrophone()` disables the local audio track
- **Self-deafen** -- `LiveKitService.toggleDeafen()` disables all remote audio playback + auto-mutes
- **Server-mute** -- moderator publishes Kind 10070 event; target client receives and disables mic
- **Screen share** -- `LiveKitService.toggleScreenShare()` uses `livekit_client` built-in support
- **Video** -- `LiveKitService.toggleCamera()` toggles camera track

### Efficiency

The Go binary runs at ~30 MB RAM idle. Built-in TURN means no coturn deployment. On a 2-core machine, LiveKit comfortably handles 30 concurrent voice users -- more than sufficient for small to medium self-hosted instances.

### When to Reconsider

- **Janus** -- if GPLv3 is acceptable and you need sub-1 GB total RAM for the entire stack (Janus idles at ~10 MB). Requires writing custom Dart signaling wrappers, but the C core is rock-solid.
- **Mesh (no SFU)** -- if the deployment will only ever have 2-3 person calls and you want zero additional infrastructure. Use raw `RTCPeerConnection` with Nostr as the signaling layer. This breaks down beyond ~4 participants.

---

## 5. Architecture Diagram

```
+----------------------------------------------------------+
|                    Flutter Client                          |
|                                                          |
|  +---------------------+   +---------------------------+ |
|  | Voice Channel Screen |   |   livekit_client (Dart)   | |
|  |                     |   |                           | |
|  | VoiceChannelScreen  |-->| Room.connect(url, token)  | |
|  | channel_sidebar     |   | localParticipant.setMic   | |
|  +--------+------------+   +-------------+-------------+ |
|           | Nostr (Kind 10070)           | WebRTC (UDP)   |
|           | voice_state events           | + TURN (TCP)   |
+-----------+--------------+---------------+----------------+
            |              |               |
            v              |               v
+------------------------+ |  +---------------------------+
|   Nostr Relays         | |  |    LiveKit Server         |
|                        | |  |    (Go binary)            |
|  Kind 10070 events     | |  |                           |
|  with #h tag for       | |  |  SFU media routing        |
|  server group ID       | |  |  Built-in TURN            |
|                        | |  |  Room management API      |
+------------------------+ |  +---------------------------+
                           |
                           v
+----------------------------------------------+
|   Voice Token Service (local or remote)       |
|                                              |
|  Local: VoiceTokenService.generateToken()    |
|    uses dart_jsonwebtoken + API key/secret   |
|                                              |
|  Remote: encrypted DM (Kind 14) to provider  |
|    request token --> provider generates -->   |
|    encrypted DM response with JWT + URL      |
+----------------------------------------------+
```

### Data Flow: Joining a Voice Channel

1. User clicks "Join Voice" in `VoiceChannelScreen`.
2. The screen checks permissions (`connectVoice`, `speak`) via `PermissionService`.
3. The app queries `ServerVoiceProviders` in Drift to find an active voice provider for the server.
4. An encrypted DM (Kind 14) is sent to the provider's pubkey via `VoiceTokenService.requestToken()`, containing the server group ID, channel ID, and user identity.
5. The provider generates a LiveKit JWT and responds with an encrypted DM containing the token and LiveKit URL.
6. `LiveKitService.connect(url: ..., token: ...)` establishes the WebRTC connection via `livekit_client`.
7. LiveKit authenticates the token, admits the user to the room, and begins SFU media routing.
8. The client publishes a Kind 10070 Nostr event with `action: "join"` and the `#h` tag set to the server's Nostr group ID.
9. All server members subscribed to Kind 10070 events for that `#h` tag receive the voice state update.
10. The channel sidebar updates to show the user under the voice channel with mute/deafen indicators.

---

## 6. Codebase Integration Points

### `lib/database/tables/channels.dart`

The `channelType` column stores `0` for text, `1` for voice, `2` for announcement. The voice channel screen is routed to when `channelType == 1`.

### `lib/models/permission.dart`

Seven voice permissions are defined in the `Permission` enum:

```dart
enum Permission {
  // ... existing permissions ...
  connectVoice,   // join voice channels
  speak,          // unmute and transmit audio
  video,          // send video in voice channels
  screenShare,    // share screen in voice channels
  muteMembers,    // server-mute other members
  deafenMembers,  // server-deafen other members
  moveMembers,    // move members between voice channels
  // ...
}
```

Each maps to a snake_case key via `PermissionExtension.key` (e.g. `connectVoice` -> `"connect_voice"`), matching the JSON permission maps stored in role data synced from the server.

### `lib/services/voice_token_service.dart`

Handles both local and remote token generation:

```dart
class VoiceTokenService {
  /// Generate a LiveKit JWT locally (when we are the voice provider)
  static String generateToken({
    required String apiKey,
    required String apiSecret,
    required String roomName,
    required String participantIdentity,
    String? participantName,
    bool canPublish = true,
    bool canSubscribe = true,
    Duration expiry = const Duration(hours: 6),
  }) {
    final claims = {
      'iss': apiKey,
      'sub': participantIdentity,
      'nbf': now.millisecondsSinceEpoch ~/ 1000,
      'exp': now.add(expiry).millisecondsSinceEpoch ~/ 1000,
      'video': {
        'room': roomName,
        'roomJoin': true,
        'canPublish': canPublish,
        'canSubscribe': canSubscribe,
      },
    };
    final jwt = JWT(claims);
    return jwt.sign(SecretKey(apiSecret), algorithm: JWTAlgorithm.HS256);
  }

  /// Request a voice token from a remote provider via encrypted Nostr DM (Kind 14)
  static Future<void> requestToken({
    required RelayPool relayPool,
    required String privateKeyHex,
    required String publicKeyHex,
    required String providerPubkey,
    required String serverGroupId,
    required String channelPublicId,
    required String requestId,
    String? userDisplayName,
  }) async { /* ... */ }

  /// Respond with a token (sent by the provider via encrypted DM)
  static Future<void> respondWithToken({
    required RelayPool relayPool,
    required String privateKeyHex,
    required String publicKeyHex,
    required String requesterPubkey,
    required String requestId,
    required String token,
    required String livekitUrl,
  }) async { /* ... */ }
}
```

Token requests and responses use NIP-44 encryption over Kind 14 events, ensuring the LiveKit credentials are never exposed to relay operators or other subscribers.

### `lib/services/livekit_service.dart`

Manages the LiveKit `Room` lifecycle, participant streams, and local media controls:

```dart
class LiveKitService {
  Room? _room;
  EventsListener<RoomEvent>? _listener;

  final _participantsController = StreamController<List<Participant>>.broadcast();
  Stream<List<Participant>> get participantsStream => _participantsController.stream;

  final _connectionController = StreamController<bool>.broadcast();
  Stream<bool> get connectionStream => _connectionController.stream;

  /// Callback to publish voice state leave before disconnecting
  Future<void> Function()? onLeaveCallback;

  /// Callback for token renewal (fires 30 min before expiry)
  Future<String?> Function()? onTokenRefreshNeeded;

  Future<void> connect({
    required String url,
    required String token,
    bool noiseSuppression = true,
    bool echoCancellation = true,
    bool autoGainControl = true,
    String suppressionLevel = 'moderate',
  }) async {
    _room = Room(
      roomOptions: RoomOptions(
        defaultAudioCaptureOptions: AudioCaptureOptions(
          noiseSuppression: noiseSuppression,
          echoCancellation: echoCancellation,
          autoGainControl: autoGainControl,
        ),
      ),
    );
    // Set up event listeners, connect, init noise processor
    await _room!.connect(url, token);
    _scheduleTokenRefresh(token);
  }

  Future<void> disconnect() async { /* publishes leave via onLeaveCallback */ }
  Future<void> toggleMicrophone() async { /* ... */ }
  Future<void> toggleDeafen() async { /* ... */ }
  Future<void> toggleCamera() async { /* ... */ }
  Future<void> toggleScreenShare() async { /* ... */ }
}
```

Key design decisions:

- **Token refresh**: parses the JWT `exp` claim and schedules renewal 30 minutes before expiry. On renewal, sends a new token request to the provider, reconnects, and restores mute state.
- **Leave callback**: `onLeaveCallback` is set by the voice channel screen so that both explicit disconnect and sidebar disconnect publish a Kind 10070 leave event.
- **Streams**: `participantsStream` and `connectionStream` drive reactive UI rebuilds.

### `lib/screens/voice/voice_channel_screen.dart`

The voice channel UI. Handles:

- Permission checking via `PermissionService` (connect, speak, video, screen share, mute/deafen/move members)
- Voice provider lookup from `ServerVoiceProviders` Drift table
- Token request/response flow via encrypted DMs
- Audio processing settings from `FlutterSecureStorage`
- Participant grid with responsive column layout (1/2/3 columns based on count)
- Speaking indicator with pulsing glow animation
- Participant profile resolution from `RemoteMembers` and `Contacts` tables
- Voice state publishing (Kind 10070 events)
- Sidechat panel (right side, 300px, when `sidechatChannelId` is set)

### `lib/widgets/channel_sidebar.dart`

Displays voice channel participants below voice channel items in the sidebar. Subscribes to Kind 10070 events for the server's `#h` tag and renders connected users with mute/deafen indicators.

---

## 7. Database Schema (Drift)

### `VoiceStates` Table

`lib/database/tables/voice_states.dart` -- tracks who is currently in which voice channel and their audio/video state:

```dart
class VoiceStates extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get userId => integer()();
  IntColumn get serverId => integer()();
  IntColumn get channelId => integer()();
  TextColumn get sessionId => text().unique()();
  BoolColumn get selfMute => boolean().withDefault(const Constant(false))();
  BoolColumn get selfDeaf => boolean().withDefault(const Constant(false))();
  BoolColumn get serverMute => boolean().withDefault(const Constant(false))();
  BoolColumn get serverDeaf => boolean().withDefault(const Constant(false))();
  BoolColumn get screenShareOn => boolean().withDefault(const Constant(false))();
  BoolColumn get videoOn => boolean().withDefault(const Constant(false))();
  BoolColumn get broadcasting => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
```

Voice state rows are populated from incoming Kind 10070 events and cleaned up on leave events. They serve as a local cache for rendering the sidebar participant list.

### `ServerVoiceProviders` Table

`lib/database/tables/server_voice_providers.dart` -- tracks which users provide voice service for a server:

```dart
class ServerVoiceProviders extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get serverId => integer()();
  IntColumn get userId => integer().nullable()();
  TextColumn get providerPubkey => text().nullable()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();
  IntColumn get position => integer().withDefault(const Constant(0))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
```

Synced from server metadata. The client picks the first active provider when joining a voice channel.

### Channel Voice Columns

The `Channels` Drift table includes voice-specific columns:

| Column | Type | Default | Description |
|---|---|---|---|
| `voiceBitrate` | integer | 64000 | Audio bitrate in bits/sec (64kbps default) |
| `voiceUserLimit` | integer | 0 | Max users (0 = unlimited) |
| `videoEnabled` | boolean | false | Whether video is allowed in this voice channel |
| `sidechatChannelId` | text (nullable) | null | Linked text channel for sidechat panel |

---

## 8. Voice State via Nostr (Kind 10070)

Instead of a server database or ActionCable broadcasts, voice state is published as **public Nostr events** (Kind 10070) with an `#h` tag containing the server's Nostr group ID. All members subscribed to that group see voice state changes in real time.

### Event Structure

```dart
final event = NostrEvent(
  pubkey: auth.publicKeyHex!,
  createdAt: NostrEvent.now(),
  kind: 10070,
  tags: [['h', server.nostrGroupId!]],
  content: jsonEncode({
    'type': 'voice_state_sync',
    'action': action,         // "join", "leave", "updated"
    'server_nostr_group_id': server.nostrGroupId,
    'channel_id': channelPublicId,
    'user_id': publicKeyHex.substring(0, 12),
    'user_pubkey': publicKeyHex,
    'username': displayName,
    'avatar_url': avatarUrl,
    'self_mute': isMuted,
    'self_deaf': isDeafened,
  }),
);
```

### Why Kind 10070

- **Public**: all server members see voice state without N encrypted DMs per state change.
- **Replaceable**: Kind 10070 is in the replaceable range (10000-19999), so relays keep only the latest event per pubkey, preventing stale state buildup.
- **Filterable**: the `#h` tag allows clients to subscribe to voice events for a specific server group only.
- **No server dependency**: works with any Nostr relay, no custom backend needed.

### Subscription

Clients subscribe to Kind 10070 events with the `#h` filter matching the current server's group ID. When a voice state event arrives, the local `VoiceStates` Drift table is updated and the sidebar re-renders.

---

## 9. Token Flow: Local vs. Remote Provider

### Local Provider (Self-Hosted LiveKit)

When the current user is the voice provider (e.g., running LiveKit on their own machine):

1. `VoiceTokenService.generateToken()` creates the JWT locally using `dart_jsonwebtoken`.
2. The token includes room name (`srv-{serverPublicId}-{channelPublicId}`), participant identity, and permission grants.
3. No network request needed -- the token is used directly with `LiveKitService.connect()`.

### Remote Provider (Another User Hosts LiveKit)

When someone else provides the LiveKit server:

1. Client sends an encrypted DM (Kind 14, NIP-44) to the provider's pubkey via `VoiceTokenService.requestToken()`.
2. The request includes: server group ID, channel ID, user pubkey, display name, and a unique request ID.
3. The provider receives the DM, generates a token using their LiveKit API key/secret, and responds with an encrypted DM containing the JWT and LiveKit URL.
4. Client waits up to 15 seconds for the response via `DmService.waitForVoiceToken(requestId)`.
5. On success, connects with the received token and URL.

### Token Renewal

Tokens are issued with a 6-hour expiry. `LiveKitService` parses the JWT `exp` claim and schedules renewal 30 minutes before expiry:

```dart
void _scheduleTokenRefresh(String token) {
  // Parse JWT payload for exp claim
  final parts = token.split('.');
  final payload = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
  final claims = json.decode(payload) as Map<String, dynamic>;
  final exp = claims['exp'] as int?;

  _tokenExpiresAt = DateTime.fromMillisecondsSinceEpoch(exp! * 1000);
  final renewAt = _tokenExpiresAt!.subtract(const Duration(minutes: 30));
  final delay = renewAt.difference(DateTime.now());

  _tokenRefreshTimer = Timer(delay, _renewToken);
}
```

On renewal, the service sends a new token request to the provider, reconnects to the room, and restores the previous mute state.

---

## 10. Audio Processing: DeepFilterNet via Native FFI

### Architecture

The Flutter app uses DeepFilterNet3 for ML-based noise suppression, loaded via native FFI. The pipeline is:

```
Microphone audio -> DeepFilterNet (STFT -> DNN -> ISTFT) -> Clean audio -> LiveKit
```

### Files

| File | Purpose |
|---|---|
| `native/deepfilter/` | Native Rust/C source for DeepFilterNet bindings |
| `hook/build.dart` | Dart native assets build hook -- compiles the native library |
| `lib/src/deepfilter_bindings.dart` | FFI function declarations (`df_create`, `df_process_frame`, etc.) |
| `lib/services/noise_processor.dart` | Dart wrapper with init, processFrame, level adjustment |
| `assets/models/DeepFilterNet3_onnx.tar.gz` | Bundled ONNX model (extracted to app support on first run) |

### FFI Bindings

```dart
// lib/src/deepfilter_bindings.dart
@Native<Pointer<Void> Function(Pointer<Utf8>, Float, Pointer<Utf8>)>(symbol: 'df_create')
external Pointer<Void> dfCreate(Pointer<Utf8> path, double attenLim, Pointer<Utf8> logLevel);

@Native<Float Function(Pointer<Void>, Pointer<Float>, Pointer<Float>)>(symbol: 'df_process_frame')
external double dfProcessFrame(Pointer<Void> st, Pointer<Float> input, Pointer<Float> output);

@Native<Size Function(Pointer<Void>)>(symbol: 'df_get_frame_length')
external int dfGetFrameLength(Pointer<Void> st);

@Native<Void Function(Pointer<Void>, Float)>(symbol: 'df_set_atten_lim')
external void dfSetAttenLim(Pointer<Void> st, double limDb);
```

The shared library is compiled from source by `hook/build.dart` and bundled automatically via Dart native assets. No manual `DynamicLibrary.open()` or path searching is needed.

### Suppression Levels

| Level | Attenuation Limit | Use Case |
|---|---|---|
| `low` | 40 dB | Light background noise (quiet room, mild fan) |
| `moderate` | 80 dB | Default -- handles keyboard, moderate ambient noise |
| `aggressive` | 95 dB | Loud environments (construction, crowded space) |

Levels can be changed at runtime via `dfSetAttenLim()` without rebuilding the model.

### Fallback Chain

```dart
class NoiseProcessor {
  Future<void> init({String level = 'moderate'}) async {
    // Try DeepFilterNet (ML-based, best quality)
    try {
      _dfState = _DeepFilterState();
      await _dfState!.init(level);
      _activeProcessor = 'deepfilter';
      return;
    } catch (e) {
      _dfState = null;
    }
    // Fall back to WebRTC built-in (handled by LiveKit AudioCaptureOptions)
    _activeProcessor = 'webrtc';
  }
}
```

DeepFilterNet handles the full pipeline internally (STFT, DNN inference, ISTFT), so no manual high-pass filter or noise gate is needed. If the native library is unavailable (e.g., unsupported platform), the app falls back to WebRTC's built-in noise suppression via `AudioCaptureOptions(noiseSuppression: true)`.

---

## 11. Moderation Flows

### Self-Mute

```
User clicks mute button
  |
  +-> LiveKitService.toggleMicrophone()
  |     localParticipant.setMicrophoneEnabled(false)
  |     -- audio track disabled locally, no server round-trip for media
  |
  +-> _publishVoiceState('updated')
  |     -- publishes Kind 10070 event with self_mute: true
  |
  +-> All subscribers receive the event
        -- sidebar controllers update the mute icon
```

### Server-Mute (Moderator Action)

```
Moderator right-clicks user -> "Server Mute"
  |
  +-> Check Permission.muteMembers via PermissionService
  |     -- returns false if not authorized
  |
  +-> Publish Kind 10070 event with:
  |     action: "server_mute"
  |     target_pubkey: <muted user's pubkey>
  |     -- all subscribers see the server-mute state
  |
  +-> Target user's client receives the event
  |     -- disables microphone locally
  |     -- UI shows "You have been server muted"
  |     -- user cannot unmute until moderator publishes server-unmute
  |
  +-> Sidebar shows server-mute icon on the user
```

Unlike the server-backed approach where LiveKit force-mutes via its REST API, the Flutter client relies on the target client honoring the moderator's Kind 10070 event. This is a trust-based model consistent with Nostr's architecture.

### Self-Deafen

```
User clicks deafen button
  |
  +-> LiveKitService.toggleDeafen()
  |     -- disables all remote audio tracks locally (mediaStreamTrack.enabled = false)
  |     -- also disables own microphone (mute on deafen)
  |     -- purely client-side, no SFU involvement
  |
  +-> _publishVoiceState('updated')
  |     -- publishes Kind 10070 event with self_deaf: true
  |
  +-> Sidebar shows deafen icon on the user
```

### Move Member

```
Moderator right-clicks user -> "Move to #voice-2"
  |
  +-> Check Permission.moveMembers via PermissionService
  |
  +-> Publish Kind 10070 event with:
  |     action: "move"
  |     target_pubkey: <user to move>
  |     target_channel_id: <destination channel>
  |
  +-> Target user's client receives the event
        -- disconnects from current room
        -- requests a new token for the target channel
        -- connects to the new room
        -- publishes Kind 10070 join event for the new channel
```

---

## 12. Screen Share

Screen sharing uses `livekit_client`'s built-in `setScreenShareEnabled()`:

```dart
Future<void> toggleScreenShare() async {
  if (_room == null) return;
  final enabled = _room!.localParticipant?.isScreenShareEnabled() ?? false;
  await _room!.localParticipant?.setScreenShareEnabled(!enabled);
  _emitParticipants();
}
```

### Platform Support

| Platform | System Audio | Notes |
|---|---|---|
| Windows | Yes | Full support via desktop capture APIs |
| macOS | Limited | macOS blocks system audio at OS level; window/screen capture works |
| Linux | Yes (PipeWire) | Requires PipeWire audio backend |
| Android | Yes | MediaProjection API (requires user permission dialog) |
| iOS | Yes | ReplayKit broadcast extension |

---

## 13. Scaling & Performance

### LiveKit Official Benchmarks

Tested on a 16-core `c2-standard-16` GCP instance:

| Scenario | Configuration | CPU Usage |
|---|---|---|
| Audio-only room | 10 speakers + 3,000 listeners | ~80% |
| Video meeting | 150 bidirectional 720p streams | ~85% |
| Livestream | 1 publisher -> 3,000 viewers | ~92% |

### Self-Hosted Resource Estimates

| Tier | Hardware | Concurrent Voice Users | Notes |
|---|---|---|---|
| Small | 2 cores, 4 GB RAM | ~50 | Suitable for a personal or small community instance |
| Medium | 4 cores, 8 GB RAM | ~200+ | Handles multiple active voice channels simultaneously |
| Large | 16 cores, 32 GB RAM | ~3,000 audio subscribers per room | Production-grade for large communities |

### Multi-Node Clustering

LiveKit supports horizontal scaling for instances that outgrow a single server:

- **Redis coordination** -- nodes register and discover each other via Redis. Room state is shared across the cluster.
- **Region-aware routing** -- participants are routed to the nearest node. Rooms can span multiple nodes with cascaded forwarding.
- **Graceful draining** -- a node marked for maintenance stops accepting new rooms and waits for existing rooms to empty before shutting down.
- **Kubernetes-native** -- Helm chart provided. Nodes auto-scale based on CPU/bandwidth metrics.
- **Room affinity** -- each room lives on a single node (no split-brain). Unlimited concurrent rooms across the cluster; rooms are distributed automatically.

For Inferno Chat, a single 2-core node is sufficient for most self-hosted instances. Add nodes only when concurrent voice usage consistently exceeds capacity.

---

## 14. Deployment

### Docker Compose (LiveKit Server Only)

The Flutter client is a standalone app -- only the LiveKit server needs deployment:

```yaml
# docker-compose.yml
services:
  livekit:
    image: livekit/livekit-server:latest
    ports:
      - "7880:7880"    # HTTP API + WebSocket signaling
      - "7881:7881"    # RTC (WebRTC over TCP fallback)
      - "50000-60000:50000-60000/udp"  # WebRTC media (UDP)
      - "5349:5349"    # TURN over TLS
    volumes:
      - ./config/livekit.yaml:/etc/livekit.yaml
    command: --config /etc/livekit.yaml
    restart: unless-stopped
```

### LiveKit Configuration

```yaml
# config/livekit.yaml
port: 7880
rtc:
  port_range_start: 50000
  port_range_end: 60000
  use_external_ip: true

keys:
  # API key : secret -- generate with `livekit-server generate-keys`
  APIxxxxxxx: "secret_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

turn:
  enabled: true
  tls_port: 5349
  cert_file: /etc/livekit/tls/cert.pem
  key_file: /etc/livekit/tls/key.pem

room:
  empty_timeout: 300       # seconds before empty room is destroyed
  max_participants: 0      # 0 = unlimited

logging:
  level: info
```

Note: No webhook configuration is needed. The Flutter client does not receive webhooks -- voice state is managed entirely via Kind 10070 Nostr events.

### Client Configuration

The voice provider's LiveKit API key and secret are stored locally by the provider user (in `FlutterSecureStorage`). Other users never need these credentials -- they request tokens via encrypted DMs.

### Firewall Ports

| Port | Protocol | Purpose |
|---|---|---|
| 7880 | TCP | LiveKit HTTP API + WebSocket signaling |
| 7881 | TCP | WebRTC over TCP (fallback when UDP is blocked) |
| 50000-60000 | UDP | WebRTC media (audio/video packets) |
| 5349 | TCP | TURN over TLS (firewall traversal for restrictive networks) |

---

## 15. Implementation Phases

### Phase 1: Audio Voice Channels (Complete)

- [x] Voice permissions in `Permission` enum (`connectVoice`, `speak`, `video`, `screenShare`, `muteMembers`, `deafenMembers`, `moveMembers`)
- [x] `VoiceStates` and `ServerVoiceProviders` Drift tables
- [x] `VoiceTokenService` with local JWT generation and encrypted DM request/response
- [x] `LiveKitService` with connect, disconnect, toggle mute/deafen, participant streams
- [x] `VoiceChannelScreen` with join flow, participant grid, speaking indicators
- [x] Kind 10070 voice state publishing (join, leave, updated)
- [x] Token refresh (30 min before expiry, re-requests from provider)
- [x] Audio processing settings from `FlutterSecureStorage`
- [x] Sidechat panel (linked text channel)

**Verification:** User can join a voice channel, see participants in a responsive grid, mute/unmute, deafen/undeafen, and disconnect. Other users see real-time voice state updates via Nostr.

### Phase 2: Native Audio Processing (Complete)

- [x] DeepFilterNet3 native FFI integration (`native/deepfilter/`, `hook/build.dart`)
- [x] `NoiseProcessor` with DeepFilterNet -> WebRTC fallback chain
- [x] Three suppression levels (low/moderate/aggressive) with live adjustment
- [x] Model asset bundling and first-run extraction
- [x] `deepfilter_bindings.dart` FFI declarations

**Verification:** Noise suppression active with DeepFilterNet on supported platforms, seamless fallback to WebRTC built-in elsewhere.

### Phase 3: Moderation

- [ ] Server-mute/unmute via Kind 10070 moderator events
- [ ] Server-deafen/undeafen via Kind 10070 moderator events
- [ ] Move member via Kind 10070 event (target client auto-reconnects to new channel)
- [ ] Right-click context menu for voice moderation actions
- [ ] Permission checks gate moderation actions in UI
- [ ] Visual indicators for server-mute and server-deafen states

**Verification:** Moderator can server-mute, server-deafen, and move members. Permission checks prevent unauthorized users. All state changes propagate via Nostr.

### Phase 4: Video + Screen Share

- [ ] Toggle camera via `LiveKitService.toggleCamera()`
- [ ] Toggle screen share via `LiveKitService.toggleScreenShare()`
- [ ] Video grid layout in participant tiles (show video track when active)
- [ ] Screen share viewer with fullscreen toggle
- [ ] Channel setting to enable/disable video per channel (`videoEnabled` column)
- [ ] Permission checks for `video` and `screenShare`

**Verification:** Users can enable video and share screen in voice channels. Video grid displays correctly. Channel admins can toggle video on/off per channel.

### Phase 5: Polish

- [ ] Voice user limit enforcement (deny join when full)
- [ ] Connection quality indicator (green/yellow/red) via `ConnectionQualityChanged` event
- [ ] Automatic reconnection with exponential backoff
- [ ] AFK detection and visual indicator
- [ ] Voice activity detection threshold (configurable sensitivity)
- [ ] Voice & Video settings screen (`lib/screens/settings/voice_video_screen.dart`) for noise suppression level, echo cancellation, auto gain control toggles

**Verification:** User limits enforced. Connection quality visible. Reconnection works after brief network drops. Settings screen allows tuning audio processing.

---

## 16. Security Considerations

- **Token expiry** -- LiveKit JWTs are issued with a 6-hour TTL. `LiveKitService` schedules renewal 30 minutes before expiry via `_scheduleTokenRefresh()`. On renewal, a new encrypted DM is sent to the provider.
- **Token secrecy** -- API keys and secrets are stored only by the voice provider in `FlutterSecureStorage`. Other users receive opaque JWTs via NIP-44 encrypted DMs (Kind 14) -- relay operators cannot read the token contents.
- **Permission scoping** -- token grants (`canPublish`, `canSubscribe`) are derived from the user's role at token generation time. Changing a role mid-session does not retroactively update grants; the user must rejoin.
- **TURN credentials** -- LiveKit's built-in TURN server uses short-lived credentials derived from the API secret. No separate TURN credential management needed.
- **Voice state authenticity** -- Kind 10070 events are signed by the publisher's Nostr keypair. Clients can verify that a voice state event genuinely came from the claimed user. Moderator events (server-mute, move) are verified against the server's role/permission data.
- **Trust model** -- Server-mute is enforced by the target client honoring the moderator's Kind 10070 event. A malicious client could ignore the event, but this is consistent with Nostr's trust model. For high-security scenarios, the voice provider can revoke the user's token via the LiveKit REST API.

---

## 17. File Reference

| File | Purpose |
|---|---|
| `lib/services/livekit_service.dart` | LiveKit room lifecycle, participant streams, media controls |
| `lib/services/voice_token_service.dart` | Local JWT generation, encrypted DM token request/response |
| `lib/services/noise_processor.dart` | DeepFilterNet wrapper with fallback chain |
| `lib/src/deepfilter_bindings.dart` | FFI declarations for DeepFilterNet native functions |
| `lib/screens/voice/voice_channel_screen.dart` | Voice channel UI, join flow, participant grid |
| `lib/screens/settings/voice_video_screen.dart` | Audio processing settings UI |
| `lib/models/permission.dart` | Permission enum including voice permissions |
| `lib/database/tables/voice_states.dart` | Drift table for local voice state cache |
| `lib/database/tables/server_voice_providers.dart` | Drift table for server voice provider config |
| `lib/database/tables/channels.dart` | Channel table with voice-specific columns |
| `native/deepfilter/` | Native Rust/C source for DeepFilterNet |
| `hook/build.dart` | Dart native assets build hook |
| `assets/models/DeepFilterNet3_onnx.tar.gz` | Bundled DeepFilterNet3 ONNX model |

---

## 18. Library Summary

| Library | Version | Purpose | Install |
|---|---|---|---|
| `livekit_client` | ^2.x | Dart WebRTC client, room connection, track management | `flutter pub add livekit_client` |
| `dart_jsonwebtoken` | ^2.x | Local JWT token generation for LiveKit | `flutter pub add dart_jsonwebtoken` |
| `livekit/livekit-server` | latest | SFU server (Docker image or binary) | `docker pull livekit/livekit-server` |
| `ffi` / `package:ffi` | (built-in) | Native FFI for DeepFilterNet bindings | (included with Flutter SDK) |

### Sources

- LiveKit documentation: https://docs.livekit.io
- LiveKit Flutter/Dart SDK: https://github.com/livekit/client-sdk-flutter
- LiveKit self-hosting guide: https://docs.livekit.io/realtime/self-hosting/
- LiveKit benchmarks: https://docs.livekit.io/realtime/self-hosting/benchmark/
- DeepFilterNet: https://github.com/Rikorose/DeepFilterNet
- dart_jsonwebtoken: https://pub.dev/packages/dart_jsonwebtoken
- NIP-44 (Encrypted DMs): https://github.com/nostr-protocol/nips/blob/master/44.md
- Janus Gateway: https://janus.conf.meetecho.com
- mediasoup: https://mediasoup.org
- Galene: https://galene.org
- Jitsi Meet: https://jitsi.org
