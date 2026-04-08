# Hierarchical Voice Channels -- Hearths & Embers

## Overview

Hierarchical voice channels enable TeamSpeak-style voice channel trees where audio cascades downward. A top-level voice channel is a **Hearth** -- the source of warmth that radiates to all channels nested beneath it. Nested channels are **Embers** -- they carry the hearth's heat with them. This is designed for organized voice communication in milsim, MMO raids, Minecraft SMPs, and tournament environments.

**Key principle: Audio flows DOWN, never up.** A hearth's audio is heard by all its embers, but embers cannot be heard by the hearth or sibling embers -- only by their own embers further down.

## Audio Cascade

```
  Command (hearth)
     |
     +-- talks ----------> heard by Team A, Team B, Squad 1, Squad 2
     |
     +-- Team A (ember)
     |      |
     |      +-- talks --> heard by Squad 1, Squad 2 (NOT by Command or Team B)
     |      |
     |      +-- Squad 1
     |      |     \-- talks -> only Squad 1 hears (no one above)
     |      |
     |      \-- Squad 2
     |            \-- talks -> only Squad 2 hears
     |
     \-- Team B (ember)
            \-- talks --> heard only within Team B
```

Each user connects to **their own channel's LiveKit room** (publish + subscribe) plus **subscribe-only connections** to every ancestor room. No server-side audio forwarding -- LiveKit handles all media routing.

### Example connections

- User in `Command` (hearth): `srv-X-command` (pub+sub)
- User in `Team A` (ember of Command): `srv-X-team-a` (pub+sub) + `srv-X-command` (sub-only, hidden)
- User in `Squad 1` (ember of Team A): `srv-X-squad-1` (pub+sub) + `srv-X-team-a` (sub-only) + `srv-X-command` (sub-only)

**Hidden tokens** (`canPublish: false` in LiveKit grant, combined with `hidden: true` metadata) prevent subscribe-only listeners from appearing in ancestor rooms' participant lists.

## Video Cascade

Screen shares and cameras from ancestor channels are also visible to embers, following the same downward-only flow. When a user in Command shares their screen, all users in Team A, Team B, Squad 1, and Squad 2 can see it.

## Nesting

Maximum depth: **3 levels** (e.g., Command -> Team -> Squad). Attempting to create a 4th level is rejected by validation in the channel creation dialog (`server_settings_overlay.dart`).

### Typical setups

- **Milsim**: Command -> Squads -> Fireteams
- **MMO Raid**: Raid Lead -> Tank/Heal/DPS groups
- **Tournament**: Admins -> Match Channels

## Monitor Mode

Hearth users can opt-in to **listen to ember audio** with per-ember volume control. This is like a commander's radio console for monitoring squad comms.

- Toggle monitoring on/off per ember
- Per-ember volume slider (default 80%, stored in Drift `voice_settings` or `shared_preferences`)
- Participant count shown for context
- When deafened, all monitored rooms are also muted

Monitor tokens use subscribe-only, hidden connections -- the hearth user does not appear in the ember room's participant list.

## Showcase Mode

Temporarily elevates an ember or individual user to be heard at the hearth level without switching channels.

### Channel Showcase (hearth-initiated)
All audio from an ember room becomes audible to everyone in the hearth. Like putting a squad on speakerphone for command.

1. Hearth user clicks "Showcase" on an ember in the monitor panel
2. Client publishes a Kind 10070 Nostr event with a `showcase` tag referencing the ember channel. All hearth clients receive the event via relay subscription.
3. All hearth clients auto-subscribe to the ember room
4. Click again to end showcase (publishes a Kind 10070 event with `showcase_end` tag)

### User Showcase (hearth-initiated)
A single user from an ember gets a temporary publish token for the hearth room.

1. Hearth user right-clicks a user in a monitored ember -> "Showcase User"
2. A Kind 10070 event is published with `showcase_user` tag identifying the target user and hearth room
3. Ember user's client receives the event, connects and publishes in hearth room
4. Hearth room participants see the showcased user with a "showcased" badge
5. End showcase -> ember user disconnects from hearth room (triggered by a `showcase_user_end` Kind 10070 event)

### Request to Speak (ember-initiated)
Ember user requests to speak at the hearth level. A hearth user approves or denies.

1. Ember user clicks "Request to Speak" button
2. Client publishes a Kind 10070 event with `request_speak` tag targeting the hearth channel
3. Hearth users see notification with Approve/Deny buttons
4. Approve -> hearth user publishes a Kind 10070 `showcase_user` event; ember user is heard in hearth
5. Deny -> hearth user publishes a Kind 10070 `request_denied` event; ember user gets notified

### Cleanup
Showcases are automatically ended when:
- Manually ended by a hearth user
- The showcased user leaves their channel (detected via Kind 10070 leave event)
- The hearth channel is emptied
- The channel hierarchy changes

## Broadcast Toggle

Hearth users have a "Broadcast" button (megaphone icon) that controls whether their audio/video radiates to embers.

- **Default: OFF** (opt-in broadcasting, not hot mic)
- When OFF: only other hearth members hear you
- When ON: ember users also hear you via ancestor connections
- Controls audio gain on the subscriber side using LiveKit data messages
- State persisted to the `broadcasting` column on the `voice_states` Drift table and communicated via Kind 10070 events for late-joining embers

## Voice State via Nostr (Kind 10070)

All voice state changes are communicated through Kind 10070 replaceable events published to the server's relay. This replaces the Rails ActionCable broadcast mechanism entirely.

### Event structure

```dart
NostrEvent(
  kind: 10070,
  tags: [
    ['h', serverNostrGroupId],            // server scope
    ['channel', channelPublicId],          // which voice channel
    ['action', 'join'],                    // join | leave | update | showcase | showcase_end | ...
    ['session', sessionId],               // unique voice session
    ['self_mute', 'false'],
    ['self_deaf', 'false'],
    ['broadcasting', 'false'],
    ['screen_share', 'false'],
    ['video', 'false'],
  ],
  content: '',
)
```

Clients subscribe to Kind 10070 events filtered by the server's `#h` tag. The `app_bootstrap_service.dart` wires up the relay listener that routes these events into the local Drift `voice_states` table.

## Permissions

- Each channel has independent role restrictions (stored as JSON in `permissions_overrides` column on the `channels` Drift table)
- A user can access an ember without access to the hearth
- Audio cascade bypasses hearth visibility (subscribe-only tokens with `hidden: true`)
- The cascade is an inherent property of the hierarchy, not permission-controlled
- Permission checks happen client-side via `lib/models/permission.dart`

## Deletion Behavior

- **Cascade delete**: Deleting a hearth destroys all its embers (enforced at the Nostr event level -- the server owner publishes delete events for all child channels)
- Users in ember channels get disconnected when the channel delete event is received via relay subscription
- VoiceStates cleaned up locally by the Drift database when channels are removed

## Token Generation

Tokens are generated in one of two ways depending on the voice provider:

1. **Local provider** (self-hosted LiveKit): `VoiceTokenService.generateToken()` creates a JWT locally using `dart_jsonwebtoken`, with the API key and secret stored in `flutter_secure_storage`.

2. **Remote provider**: `VoiceTokenService.requestToken()` sends a NIP-44 encrypted DM (Kind 14) to the voice provider's Nostr pubkey. The provider responds with a signed token via an encrypted reply. See `lib/services/voice_token_service.dart`.

For hierarchical channels, ancestor room tokens are generated with `canPublish: false` and `canSubscribe: true` to enforce the downward-only audio flow.

## Data Model

### channels Drift table (`lib/database/tables/channels.dart`)
- `parentChannelId` (IntColumn, nullable) -- references another channel's `id` to form the tree

### voice_states Drift table (`lib/database/tables/voice_states.dart`)
- `broadcasting` (BoolColumn, default: false)
- `selfMute`, `selfDeaf`, `serverMute`, `serverDeaf`
- `screenShareOn`, `videoOn`
- `sessionId` (unique per voice session)

### voice_showcases (not yet implemented)
When showcase mode is built, a `voice_showcases` Drift table will be needed:
- `serverId` (int)
- `parentChannelId` (int) -- the hearth
- `childChannelId` (int) -- the ember
- `userId` (int, nullable -- null = whole channel showcase)
- `approvedById` (int)
- Showcase state is also communicated via Kind 10070 events so all clients stay in sync without a central server

## Key Files

| File | Purpose |
|------|---------|
| `lib/database/tables/channels.dart` | Channel table with `parentChannelId` for tree structure |
| `lib/database/tables/voice_states.dart` | Voice state table with `broadcasting` flag |
| `lib/services/livekit_service.dart` | LiveKit room connection, participant streams, audio processing |
| `lib/services/voice_token_service.dart` | Local JWT generation and remote NIP-44 token requests |
| `lib/screens/voice/voice_channel_screen.dart` | Voice channel UI, join/leave, mute/deafen, permissions |
| `lib/services/app_bootstrap_service.dart` | Wires Kind 10070 relay listener into Drift voice_states |
| `lib/widgets/channel_sidebar.dart` | Renders nested voice channel tree (hearth/ember hierarchy) |
| `lib/widgets/channel_reorder.dart` | Drag-and-drop reordering respecting parent/child relationships |
| `lib/screens/server_settings/server_settings_overlay.dart` | Channel creation/editing with parent channel picker |
| `lib/models/permission.dart` | Client-side permission evaluation |
| `lib/widgets/participant_tile.dart` | Individual voice participant rendering |

## Implementation Status

The foundational pieces are in place:
- `parentChannelId` column on the channels table
- Channel sidebar renders nested voice channels
- Kind 10070 events for voice state join/leave/update
- LiveKit connection with local and remote token generation
- Broadcasting flag on voice_states

**Not yet implemented:**
- Multi-room LiveKit connections (ancestor subscribe-only rooms)
- Monitor mode UI and per-ember volume controls
- Showcase mode (channel showcase, user showcase, request to speak)
- Hidden participant metadata for subscribe-only connections
- Broadcast toggle UI in the voice channel screen
