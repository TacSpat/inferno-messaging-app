# Hierarchical Voice Channels — Hearths & Embers

## Overview

Hierarchical voice channels enable TeamSpeak-style voice channel trees where audio cascades downward. A top-level voice channel is a **Hearth** — the source of warmth that radiates to all channels nested beneath it. Nested channels are **Embers** — they carry the hearth's heat with them. This is designed for organized voice communication in milsim, MMO raids, Minecraft SMPs, and tournament environments.

**Key principle: Audio flows DOWN, never up.** A hearth's audio is heard by all its embers, but embers cannot be heard by the hearth or sibling embers — only by their own embers further down.

## Audio Cascade

```
  Command (hearth)
     │
     ├── talks ──────────► heard by Team A, Team B, Squad 1, Squad 2
     │
     ├── Team A (ember)
     │      │
     │      ├── talks ──► heard by Squad 1, Squad 2 (NOT by Command or Team B)
     │      │
     │      ├── Squad 1
     │      │     └── talks → only Squad 1 hears (no one above)
     │      │
     │      └── Squad 2
     │            └── talks → only Squad 2 hears
     │
     └── Team B (ember)
            └── talks ──► heard only within Team B
```

Each user connects to **their own channel's LiveKit room** (publish + subscribe) plus **subscribe-only connections** to every ancestor room. No server-side audio forwarding — LiveKit handles all media routing.

### Example connections

- User in `Command` (hearth): `srv-X-command` (pub+sub)
- User in `Team A` (ember of Command): `srv-X-team-a` (pub+sub) + `srv-X-command` (sub-only, hidden)
- User in `Squad 1` (ember of Team A): `srv-X-squad-1` (pub+sub) + `srv-X-team-a` (sub-only) + `srv-X-command` (sub-only)

**Hidden tokens** (`hidden: true` in LiveKit grant) prevent subscribe-only listeners from appearing in ancestor rooms' participant lists.

## Video Cascade

Screen shares and cameras from ancestor channels are also visible to embers, following the same downward-only flow. When a user in Command shares their screen, all users in Team A, Team B, Squad 1, and Squad 2 can see it.

## Nesting

Maximum depth: **3 levels** (e.g., Command → Team → Squad). Attempting to create a 4th level is rejected by validation.

### Typical setups

- **Milsim**: Command → Squads → Fireteams
- **MMO Raid**: Raid Lead → Tank/Heal/DPS groups
- **Tournament**: Admins → Match Channels

## Monitor Mode

Hearth users can opt-in to **listen to ember audio** with per-ember volume control. This is like a commander's radio console for monitoring squad comms.

- Toggle monitoring on/off per ember
- Per-ember volume slider (default 80%, stored in localStorage)
- Participant count shown for context
- When deafened, all monitored rooms are also muted

Monitor tokens use subscribe-only, hidden connections — the hearth user doesn't appear in the ember room's participant list.

## Showcase Mode

Temporarily elevates an ember or individual user to be heard at the hearth level without switching channels.

### Channel Showcase (hearth-initiated)
All audio from an ember room becomes audible to everyone in the hearth. Like putting a squad on speakerphone for command.

1. Hearth user clicks "Showcase" on an ember in the monitor panel
2. Server creates `VoiceShowcase` record, broadcasts to all hearth clients
3. All hearth clients auto-subscribe to ember room
4. Click again to end showcase

### User Showcase (hearth-initiated)
A single user from an ember gets a temporary publish token for the hearth room.

1. Hearth user right-clicks a user in a monitored ember → "Showcase User"
2. Ember user's client connects and publishes in hearth room
3. Hearth room participants see the showcased user with a "showcased" badge
4. End showcase → ember user disconnects from hearth room

### Request to Speak (ember-initiated)
Ember user requests to speak at the hearth level. A hearth user approves or denies.

1. Ember user clicks "Request to Speak" button
2. Hearth users see notification with Approve/Deny buttons
3. Approve → creates showcase, ember user is heard in hearth
4. Deny → ember user gets notified

### Cleanup
Showcases are automatically destroyed when:
- Manually ended by a hearth user
- The showcased user leaves their channel
- The hearth channel is emptied
- The channel hierarchy changes

## Broadcast Toggle

Hearth users have a "Broadcast" button (megaphone icon) that controls whether their audio/video radiates to embers.

- **Default: OFF** (opt-in broadcasting, not hot mic)
- When OFF: only other hearth members hear you
- When ON: ember users also hear you via ancestor connections
- Controls audio gain on the subscriber side using LiveKit data messages
- State persisted to VoiceState for late-joining embers

## Permissions

- Each channel has independent role restrictions
- A user can access an ember without access to the hearth
- Audio cascade bypasses hearth visibility (subscribe-only tokens with `hidden: true`)
- The cascade is an inherent property of the hierarchy, not permission-controlled

## Deletion Behavior

- **Cascade delete**: Deleting a hearth destroys all its embers (`on_delete: :cascade` FK)
- Users in ember channels get disconnected via `channel_destroyed` broadcast
- VoiceStates cleaned up by `dependent: :destroy` on Channel

## Data Model

### channels table
- `parent_channel_id` (bigint, nullable, FK → channels with cascade delete)

### voice_showcases table
- `server_id` (FK)
- `parent_channel_id` (FK → channels) — the hearth
- `child_channel_id` (FK → channels) — the ember
- `user_id` (FK, nullable — null = whole channel showcase)
- `approved_by_id` (FK → users)

### voice_states table
- `broadcasting` (boolean, default: false)

## Key Files

| File | Purpose |
|------|---------|
| `app/models/channel.rb` | `parent_channel`, `child_channels`, `ancestor_channels` |
| `app/services/livekit_token_service.rb` | `generate_subscribe_only_token` |
| `app/controllers/voice_channels_controller.rb` | `join` (ancestor_rooms), `monitor` |
| `app/controllers/voice_showcases_controller.rb` | Showcase CRUD, request/approve/deny |
| `app/models/voice_showcase.rb` | Model with broadcast hooks |
| `app/javascript/controllers/voice_channel_controller.js` | Multi-room connections, monitor, broadcast |
| `app/views/channels/show_voice.html.erb` | Monitor panel UI |
| `app/views/channels/_channel_item.html.erb` | Nested ember rendering |
