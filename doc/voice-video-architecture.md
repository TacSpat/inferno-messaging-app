# Voice & Video Channels — Architecture

## Overview

This document describes the architecture for adding Discord-style voice and video channels to Inferno Chat. The `channel_type: :voice` enum value already exists in `app/models/channel.rb` (value `1`) but is currently unimplemented. This design covers SFU selection, database schema, Rails integration, client-side WebRTC, moderation flows, and phased implementation.

The guiding principle is **minimal new infrastructure**: one additional service (the SFU), no new ActionCable channels, and tight integration with the existing permission and broadcast systems.

---

## 1. Requirements

| User Requirement | Technical Capability | Where It Lives |
|---|---|---|
| Move users between voice channels | SFU move-participant API | `LivekitRoomService` wrapper → LiveKit REST |
| Mute an individual member | SFU server-side mute | `LivekitRoomService#mute_participant` + `mute_members` permission |
| Server-wide mute (e.g. stage mode) | SFU room-level permissions | LiveKit room metadata + grants |
| Self-mute / self-deafen | Client-side track disable | `voice_channel_controller.js` → `livekit-client` |
| Permission checks for voice actions | New voice keys in Role JSONB | `DEFAULT_PERMISSIONS` in `app/models/role.rb` |
| Screen share with optional audio | SFU screen share track | `getDisplayMedia({ audio: true, video: true })` |
| See who is in what call | ActionCable broadcasts + DB | `voice_states` table → `ServerChannel` broadcasts |

---

## 2. WebRTC Topology Primer

Three topologies exist for multi-party WebRTC:

```
Mesh (P2P)                  SFU                         MCU

A ◄──► B               A ──► ┌─────┐ ──► B        A ──► ┌─────┐ ──► A
│ ╲  ╱ │               │     │ SFU │     │         │     │ MCU │     │
│  ╲╱  │               │     │     │     │         │     │ Mix │     │
│  ╱╲  │               │     │     │     │         │     │     │     │
│ ╱  ╲ │               │     └─────┘     │         │     └─────┘     │
C ◄──► D               C ──►         ──► D        C ──►           ──► D

N*(N-1)/2 connections   N connections (up)          N connections
each peer encodes       1 encode per peer           1 encode per peer
N-1 times               server forwards             server mixes into
                        selectively                  single stream
```

**Why SFU:**

- **Mesh** fails beyond ~4 users — each peer must encode and upload N-1 streams, saturating residential upload bandwidth. Acceptable only for 1:1 calls.
- **MCU** is server-expensive — it decodes every stream, mixes them into a single composite, and re-encodes. CPU cost scales with participant count. No modern chat platform uses this.
- **SFU** is the sweet spot: each peer sends one upload, the server forwards selectively without transcoding. CPU cost is low (routing, not encoding). This is what Discord, Slack, Teams, and Meet all use.

---

## 3. SFU Options Comparison

### Full Comparison

| Criteria | LiveKit | Janus | mediasoup | Galene | Jitsi |
|---|---|---|---|---|---|
| Language | Go | C | Node + C++ | Go | Java + JS |
| License | Apache 2.0 | GPLv3 | ISC | MIT | Apache 2.0 |
| Ruby SDK | **Yes** (`livekit-server-sdk` v0.8.3) | No | No | No | No |
| JavaScript SDK | Yes (`livekit-client`) | Yes (janus.js) | Yes (mediasoup-client) | Yes (built-in) | Yes (lib-jitsi-meet) |
| Self-host complexity | Docker one-liner / single binary | Complex (deps, plugin config) | Node sidecar + custom signaling | Single binary | Very complex (Oressbar, Ojicofo, JVB, Orosody) |
| Built-in TURN | Yes (integrated) | No (needs coturn) | No (needs coturn) | No (needs coturn) | Yes (built-in Orosody) |
| Server-side mute/kick | Native API | Plugin-dependent | Custom implementation | No API | REST API |
| Move participant | Native API | No | No | No | Partial |
| Webhooks | Native (HTTP POST) | No | No | No | Yes |
| Recording | Built-in (Egress) | Plugin | No | No | Jibri (separate service) |
| Simulcast | Yes | Yes | Yes | Yes | Yes |
| RAM idle | ~30 MB | ~10 MB | ~40 MB | ~15 MB | ~500 MB+ |
| GitHub stars | 20k+ | 8k+ | 6k+ | 1k+ | 22k+ |
| Project age | ~4 years | 10+ years | ~7 years | ~4 years | 15+ years |

### LiveKit

Modern Go-based SFU built for exactly this use case. Only option with a first-party Ruby SDK, meaning token generation and room management integrate directly into Rails without HTTP client wrappers. Native webhooks map cleanly to a Rails controller + Sidekiq. Built-in TURN eliminates the need for a separate coturn deployment. Single binary or Docker image, ~30 MB RAM idle.

**Pros:** Ruby SDK, batteries-included (TURN, webhooks, recording), excellent docs, active development, Apache 2.0.
**Cons:** Youngest project on this list, though 4 years and 20k+ stars indicate strong adoption.

### Janus

Battle-tested C-based media server, extremely mature. Very low memory footprint (~10 MB). Plugin architecture is flexible but means more integration work — there is no Ruby SDK and no webhook system; you poll or write a custom event handler plugin.

**Pros:** Proven at scale, minimal RAM, GPLv3 is fine for self-hosted deployments.
**Cons:** No Ruby SDK, no webhooks, complex deployment, plugin system requires C knowledge for customization. GPLv3 may conflict if the project ever changes license.

### mediasoup

Node.js signaling layer with C++ media workers. Highly flexible — you build your own signaling server. This is more of a library than a turnkey solution.

**Pros:** ISC license, very flexible, strong community.
**Cons:** Requires a Node.js sidecar process, no Ruby SDK, no built-in TURN/webhooks/moderation, significant custom code needed.

### Galene

Lightweight Go-based SFU designed for videoconferencing. Single binary, very low footprint. However, it has no server-side moderation API, no webhooks, and a much smaller community.

**Pros:** MIT license, tiny footprint, simple deployment.
**Cons:** No Ruby SDK, no moderation API, no webhooks, small community, limited feature set for a chat platform.

### Jitsi

The most feature-complete open-source video platform. Full-featured out of the box with recording, transcription, and more. However, it is an entire application stack (Java + JS + multiple services), not an embeddable component. Deployment is complex and resource-heavy (~500 MB+ RAM idle).

**Pros:** Apache 2.0, extremely feature-rich, huge community, built-in TURN.
**Cons:** Very complex deployment (5+ services), no Ruby SDK, heavy resource usage, designed as a standalone app rather than an embeddable SFU.

---

## 4. Recommendation: LiveKit

Three-tier reasoning:

### Integration

LiveKit is the **only SFU with a Ruby SDK**. Token generation, room management, and participant control are native Ruby method calls, not hand-rolled HTTP requests. Webhooks are standard HTTP POST to a Rails controller, which can enqueue Sidekiq jobs for state updates. No sidecar process, no custom signaling server, no protocol adapter — just a Go binary alongside the existing Rails stack.

### Features

Every moderation requirement maps to a native LiveKit API call:

- **Server-side mute** → `RoomServiceClient#mute_published_track`
- **Server-side deafen** → `RoomServiceClient#update_participant` (revoke `can_subscribe`)
- **Kick from channel** → `RoomServiceClient#remove_participant`
- **Move to another channel** → Remove from current room + issue new token for target room
- **List participants** → `RoomServiceClient#list_participants`

No plugins, no custom C code, no workarounds.

### Efficiency

The Go binary runs at ~30 MB RAM idle. Built-in TURN means no coturn deployment. On a 2-core machine, LiveKit comfortably handles 30 concurrent voice users — more than sufficient for small to medium self-hosted instances. Horizontal scaling is supported via Redis coordination for multi-node clusters.

### When to Reconsider

- **Janus** — if GPLv3 is acceptable and you need sub-1 GB total RAM for the entire stack (Janus idles at ~10 MB). Requires writing a custom webhook plugin and HTTP client wrappers for Ruby, but the C core is rock-solid.
- **Mesh (no SFU)** — if the deployment will only ever have 2–3 person calls and you want zero additional infrastructure. Use `simple-peer` or raw `RTCPeerConnection` with Rails as the signaling server via ActionCable. This breaks down beyond ~4 participants.

---

## 5. Architecture Diagram

```
┌──────────────────────────────────────────────────────────┐
│                        Browser                           │
│                                                          │
│  ┌─────────────────────┐   ┌──────────────────────────┐  │
│  │ Stimulus Controllers │   │   livekit-client (JS)    │  │
│  │                     │   │                          │  │
│  │ voice_channel_ctrl  │──►│ Room.connect(url, token) │  │
│  │ channel_sidebar_ctrl│   │ localParticipant.setMic  │  │
│  └────────┬────────────┘   └────────────┬─────────────┘  │
│           │ ActionCable                  │ WebRTC (UDP)   │
│           │ (voice_state_update)         │ + TURN (TCP)   │
└───────────┼──────────────────────────────┼───────────────┘
            │                              │
            ▼                              ▼
┌───────────────────────┐     ┌─────────────────────────┐
│     Rails (Puma)      │     │    LiveKit Server        │
│                       │     │    (Go binary)           │
│ LivekitTokenService   │────►│                         │
│   generate_token()    │     │  SFU media routing      │
│                       │     │  Built-in TURN          │
│ LivekitRoomService    │────►│  Room management API    │
│   mute/kick/move      │     │                         │
│                       │     │                         │
│ LivekitWebhooksCtrl   │◄────│  HTTP POST webhooks     │
│   participant_joined  │     │  (participant_joined,   │
│   participant_left    │     │   participant_left,     │
│   track_published     │     │   track_published,     │
│                       │     │   track_unpublished)    │
│ ServerChannel         │     │                         │
│   broadcast_to(server,│     └─────────────────────────┘
│   voice_state_update) │
│                       │
│ VoiceState (model)    │
│   user ↔ channel      │
└───────────────────────┘
```

### Data Flow: Joining a Voice Channel

1. User clicks a voice channel in the sidebar.
2. Browser sends a Turbo/fetch request to `VoiceChannelsController#join`.
3. Rails checks permissions (`connect_voice` on the user's role).
4. `LivekitTokenService.generate_token` creates a JWT with the user's identity, room name (channel public_id), and permission-scoped grants (can publish audio/video based on role).
5. Rails returns the token and LiveKit server URL to the browser.
6. `voice_channel_controller.js` calls `Room.connect(url, token)` via `livekit-client`.
7. LiveKit authenticates the token, admits the user to the room, and begins SFU media routing.
8. LiveKit fires a `participant_joined` webhook to `LivekitWebhooksController`.
9. The controller creates a `VoiceState` record and broadcasts via `ServerChannel.broadcast_to(server, { type: "voice_state_update", ... })`.
10. All connected browsers receive the broadcast. `channel_sidebar_controller.js` updates the sidebar to show the user under the voice channel.

---

## 6. Codebase Integration Points

### `app/models/channel.rb`

The `voice: 1` enum already exists. Add columns for voice channel settings and a `has_many :voice_states` association:

```ruby
# Existing
enum :channel_type, { text: 0, voice: 1, announcement: 2 }

# Add association
has_many :voice_states, dependent: :destroy

# Add helper
def voice?
  channel_type == "voice"
end
```

New columns: `voice_bitrate` (integer, default 64000), `voice_user_limit` (integer, default 0 = unlimited), `video_enabled` (boolean, default false).

### `app/models/role.rb`

Add 7 voice permissions to `DEFAULT_PERMISSIONS`:

```ruby
DEFAULT_PERMISSIONS = {
  # ... existing 22 permissions ...
  connect_voice: true,     # join voice channels
  speak: true,             # unmute and transmit audio
  video: false,            # send video in voice channels
  screen_share: false,     # share screen in voice channels
  mute_members: false,     # server-mute other members
  deafen_members: false,   # server-deafen other members
  move_members: false      # move members between voice channels
}.freeze
```

Corresponding updates to `ADMIN_PERMISSIONS` (add `mute_members: true`, `deafen_members: true`, `move_members: true`) and `OWNER_PERMISSIONS`.

### `app/javascript/controllers/role_editor_controller.js`

Add a `Voice` group to `PERMISSION_GROUPS`:

```javascript
const PERMISSION_GROUPS = {
  // ... existing groups ...
  Voice: {
    connect_voice: "Join voice channels",
    speak: "Speak in voice channels",
    video: "Send video in voice channels",
    screen_share: "Share their screen in voice channels",
    mute_members: "Server-mute other members in voice",
    deafen_members: "Server-deafen other members in voice",
    move_members: "Move members between voice channels"
  },
  // Dangerous group stays last
}
```

### `app/channels/server_channel.rb`

No new ActionCable channel needed. Extend the existing `ServerChannel` with a new broadcast type:

```ruby
# Called from LivekitWebhooksController or VoiceState callbacks
ServerChannel.broadcast_to(server, {
  type: "voice_state_update",
  channel_id: channel.public_id,
  user_id: user.public_id,
  username: user.username,
  avatar_url: user.avatar_url,
  action: "joined",  # or "left", "muted", "deafened", "video_on", "screen_share_on"
  self_mute: voice_state.self_mute,
  self_deaf: voice_state.self_deaf,
  server_mute: voice_state.server_mute,
  server_deaf: voice_state.server_deaf,
  video_on: voice_state.video_on,
  screen_share_on: voice_state.screen_share_on
})
```

### `app/javascript/controllers/channel_sidebar_controller.js`

Add a `voice_state_update` case to the existing `handleMessage` switch:

```javascript
case "voice_state_update":
  this.updateVoiceState(data)
  break
```

The `updateVoiceState` method updates participant lists below voice channel items and manages mute/deafen/video icons.

The `buildChannelHtml` method needs a channel_type-aware icon: `#` for text, speaker icon for voice, megaphone for announcement.

### `app/views/channels/_channel_item.html.erb`

Branch on `channel.voice?` to render a speaker icon instead of `#`, and append a participant list below voice channels:

```erb
<% if channel.voice? %>
  <svg class="w-5 h-5 mr-1.5 opacity-60"><!-- speaker icon --></svg>
<% else %>
  <span class="text-lg mr-1.5 opacity-60">#</span>
<% end %>
```

Below voice channel items, render connected participants (from `voice_states`):

```erb
<% if channel.voice? && channel.voice_states.any? %>
  <div class="ml-8 space-y-0.5">
    <% channel.voice_states.includes(:user).each do |vs| %>
      <div class="flex items-center text-xs text-gray-400 py-0.5">
        <%= image_tag vs.user.avatar_url, class: "w-5 h-5 rounded-full mr-1.5" %>
        <span class="truncate"><%= vs.user.display_name %></span>
        <!-- mute/deafen icons -->
      </div>
    <% end %>
  </div>
<% end %>
```

### `app/policies/server_policy.rb`

Add three new policy methods following the existing pattern:

```ruby
def mute_voice_member?
  member_has_permission?("mute_members")
end

def deafen_voice_member?
  member_has_permission?("deafen_members")
end

def move_voice_member?
  member_has_permission?("move_members")
end
```

---

## 7. Database Schema

### `voice_states` Table

Tracks who is currently in which voice channel and their audio/video state. Rows are created on join, destroyed on leave.

```ruby
create_table :voice_states do |t|
  t.references :user, null: false, foreign_key: true
  t.references :channel, null: false, foreign_key: true
  t.references :server, null: false, foreign_key: true
  t.boolean :self_mute, default: false, null: false
  t.boolean :self_deaf, default: false, null: false
  t.boolean :server_mute, default: false, null: false
  t.boolean :server_deaf, default: false, null: false
  t.boolean :video_on, default: false, null: false
  t.boolean :screen_share_on, default: false, null: false
  t.string :session_id, null: false         # LiveKit participant session ID
  t.string :public_id, null: false          # HasPublicId concern

  t.timestamps
end

add_index :voice_states, [:user_id, :server_id], unique: true  # one voice channel per user per server
add_index :voice_states, :channel_id
add_index :voice_states, :public_id, unique: true
add_index :voice_states, :session_id, unique: true
```

### Channel Additions

```ruby
add_column :channels, :voice_bitrate, :integer, default: 64000   # bits/sec (64kbps default)
add_column :channels, :voice_user_limit, :integer, default: 0    # 0 = unlimited
add_column :channels, :video_enabled, :boolean, default: false
```

### Instance Config Additions

Added to the existing `instance_configs` table (or `InstanceConfig` singleton):

| Setting | Type | Default | Description |
|---|---|---|---|
| `voice_enabled` | boolean | `false` | Master toggle for voice/video features instance-wide |
| `max_voice_participants_per_channel` | integer | `25` | Global cap per voice channel (0 = unlimited) |

---

## 8. Ruby SDK Integration

### LivekitTokenService

Generates JWT tokens for browser clients to connect to LiveKit rooms.

```ruby
# app/services/livekit_token_service.rb
class LivekitTokenService
  def initialize
    @api_key = Rails.application.credentials.dig(:livekit, :api_key)
    @api_secret = Rails.application.credentials.dig(:livekit, :api_secret)
  end

  def generate_token(user:, channel:, permissions: {})
    token = LiveKit::AccessToken.new(api_key: @api_key, api_secret: @api_secret)
    token.identity = user.public_id
    token.name = user.display_name
    token.metadata = { user_id: user.public_id, server_id: channel.server.public_id }.to_json

    token.add_grant(LiveKit::VideoGrant.new(
      room_join: true,
      room: channel.public_id,
      can_publish: permissions[:speak] != false,
      can_subscribe: true,
      can_publish_data: true
    ))

    token.to_jwt
  end
end
```

### LivekitRoomService

Wraps `LiveKit::RoomServiceClient` for server-side moderation actions.

```ruby
# app/services/livekit_room_service.rb
class LivekitRoomService
  def initialize
    @client = LiveKit::RoomServiceClient.new(
      Rails.application.credentials.dig(:livekit, :url),
      Rails.application.credentials.dig(:livekit, :api_key),
      Rails.application.credentials.dig(:livekit, :api_secret)
    )
  end

  def mute_participant(channel:, user_public_id:, track_sid:)
    @client.mute_published_track(
      room: channel.public_id,
      identity: user_public_id,
      track_sid: track_sid,
      muted: true
    )
  end

  def remove_participant(channel:, user_public_id:)
    @client.remove_participant(
      room: channel.public_id,
      identity: user_public_id
    )
  end

  def update_participant_permissions(channel:, user_public_id:, can_publish: nil, can_subscribe: nil)
    @client.update_participant(
      room: channel.public_id,
      identity: user_public_id,
      permission: LiveKit::ParticipantPermission.new(
        can_publish: can_publish,
        can_subscribe: can_subscribe,
        can_publish_data: true
      )
    )
  end

  def list_participants(channel:)
    @client.list_participants(room: channel.public_id)
  end

  def list_rooms
    @client.list_rooms
  end
end
```

### LivekitWebhooksController

Receives LiveKit webhook events and updates `VoiceState` records accordingly.

```ruby
# app/controllers/livekit_webhooks_controller.rb
class LivekitWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_webhook_signature

  def create
    event = LiveKit::WebhookReceiver.new(
      api_key: Rails.application.credentials.dig(:livekit, :api_key),
      api_secret: Rails.application.credentials.dig(:livekit, :api_secret)
    ).receive(request.body.read, request.headers["Authorization"])

    case event.event
    when "participant_joined"
      handle_participant_joined(event)
    when "participant_left"
      handle_participant_left(event)
    when "track_published"
      handle_track_published(event)
    when "track_unpublished"
      handle_track_unpublished(event)
    end

    head :ok
  end

  private

  def handle_participant_joined(event)
    user = User.find_by!(public_id: event.participant.identity)
    channel = Channel.find_by!(public_id: event.room.name)

    voice_state = VoiceState.create!(
      user: user,
      channel: channel,
      server: channel.server,
      session_id: event.participant.sid
    )

    broadcast_voice_state(channel.server, channel, user, voice_state, "joined")
  end

  def handle_participant_left(event)
    voice_state = VoiceState.find_by(session_id: event.participant.sid)
    return unless voice_state

    server = voice_state.server
    channel = voice_state.channel
    user = voice_state.user

    voice_state.destroy!
    broadcast_voice_state(server, channel, user, nil, "left")
  end

  def handle_track_published(event)
    voice_state = VoiceState.find_by(session_id: event.participant.sid)
    return unless voice_state

    case event.track.source
    when "SCREEN_SHARE"
      voice_state.update!(screen_share_on: true)
    when "CAMERA"
      voice_state.update!(video_on: true)
    end

    broadcast_voice_state(voice_state.server, voice_state.channel, voice_state.user, voice_state, "updated")
  end

  def handle_track_unpublished(event)
    voice_state = VoiceState.find_by(session_id: event.participant.sid)
    return unless voice_state

    case event.track.source
    when "SCREEN_SHARE"
      voice_state.update!(screen_share_on: false)
    when "CAMERA"
      voice_state.update!(video_on: false)
    end

    broadcast_voice_state(voice_state.server, voice_state.channel, voice_state.user, voice_state, "updated")
  end

  def broadcast_voice_state(server, channel, user, voice_state, action)
    ServerChannel.broadcast_to(server, {
      type: "voice_state_update",
      channel_id: channel.public_id,
      user_id: user.public_id,
      username: user.username,
      avatar_url: user.avatar_url,
      action: action,
      self_mute: voice_state&.self_mute || false,
      self_deaf: voice_state&.self_deaf || false,
      server_mute: voice_state&.server_mute || false,
      server_deaf: voice_state&.server_deaf || false,
      video_on: voice_state&.video_on || false,
      screen_share_on: voice_state&.screen_share_on || false
    })
  end

  def verify_webhook_signature
    # LiveKit::WebhookReceiver handles signature verification internally
    # via the Authorization header and API secret
  end
end
```

---

## 9. Client-Side JavaScript

### `voice_channel_controller.js`

Stimulus controller for voice channel interaction. Uses `livekit-client` for WebRTC.

```javascript
// app/javascript/controllers/voice_channel_controller.js
import { Controller } from "@hotwired/stimulus"
import {
  Room,
  RoomEvent,
  Track,
  LocalParticipant,
  ConnectionQuality
} from "livekit-client"

export default class extends Controller {
  static values = {
    livekitUrl: String,
    token: String,
    channelId: String,
    serverId: String
  }

  static targets = ["controls", "participants", "status"]

  async connect() {
    this.room = new Room({
      adaptiveStream: true,
      dynacast: true,
      audioCaptureDefaults: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      }
    })

    this.setupEventHandlers()
  }

  async join() {
    try {
      await this.room.connect(this.livekitUrlValue, this.tokenValue)
      await this.room.localParticipant.setMicrophoneEnabled(true)
      this.updateControlsUI()
    } catch (error) {
      console.error("Failed to join voice channel:", error)
    }
  }

  async disconnect() {
    await this.room.disconnect()
    this.updateControlsUI()
  }

  async toggleMute() {
    const enabled = this.room.localParticipant.isMicrophoneEnabled
    await this.room.localParticipant.setMicrophoneEnabled(!enabled)
    this.notifySelfMute(!enabled)
  }

  async toggleDeafen() {
    // Deafen = disable all incoming audio tracks locally
    const participants = this.room.remoteParticipants
    const shouldDeafen = !this._deafened
    this._deafened = shouldDeafen

    participants.forEach((participant) => {
      participant.audioTrackPublications.forEach((pub) => {
        if (pub.track) pub.track.setEnabled(!shouldDeafen)
      })
    })

    // Also mute self when deafening
    if (shouldDeafen) {
      await this.room.localParticipant.setMicrophoneEnabled(false)
    }

    this.notifySelfDeafen(shouldDeafen)
    this.updateControlsUI()
  }

  async toggleVideo() {
    const enabled = this.room.localParticipant.isCameraEnabled
    await this.room.localParticipant.setCameraEnabled(!enabled)
  }

  async shareScreen() {
    try {
      const enabled = this.room.localParticipant.isScreenShareEnabled
      await this.room.localParticipant.setScreenShareEnabled(!enabled, {
        audio: true,  // capture system audio if supported
        selfBrowserSurface: "exclude",
        surfaceSwitching: "include"
      })
    } catch (error) {
      // User cancelled the screen share picker
      if (error.name !== "NotAllowedError") {
        console.error("Screen share error:", error)
      }
    }
  }

  // --- Event Handlers ---

  setupEventHandlers() {
    this.room.on(RoomEvent.ActiveSpeakersChanged, (speakers) => {
      this.updateSpeakingIndicators(speakers)
    })

    this.room.on(RoomEvent.TrackMuted, (publication, participant) => {
      this.updateParticipantUI(participant)
    })

    this.room.on(RoomEvent.TrackUnmuted, (publication, participant) => {
      this.updateParticipantUI(participant)
    })

    this.room.on(RoomEvent.ConnectionQualityChanged, (quality, participant) => {
      this.updateConnectionIndicator(participant, quality)
    })

    this.room.on(RoomEvent.Disconnected, (reason) => {
      this.handleDisconnect(reason)
    })

    this.room.on(RoomEvent.Reconnecting, () => {
      this.showReconnecting()
    })

    this.room.on(RoomEvent.Reconnected, () => {
      this.hideReconnecting()
    })
  }

  // ... UI update methods (updateControlsUI, updateSpeakingIndicators, etc.)

  notifySelfMute(muted) {
    fetch(`/voice_states/self_mute`, {
      method: "PATCH",
      headers: { "X-CSRF-Token": document.querySelector("[name=csrf-token]").content },
      body: JSON.stringify({ self_mute: muted })
    })
  }

  notifySelfDeafen(deafened) {
    fetch(`/voice_states/self_deafen`, {
      method: "PATCH",
      headers: { "X-CSRF-Token": document.querySelector("[name=csrf-token]").content },
      body: JSON.stringify({ self_deaf: deafened })
    })
  }
}
```

### Screen Share Browser Compatibility

| Browser | OS | System Audio | Tab Audio | Notes |
|---|---|---|---|---|
| Chrome | Windows | Yes | Yes | Full support via `getDisplayMedia({ audio: true })` |
| Chrome | macOS | No | Yes (tab only) | macOS blocks system audio capture at OS level |
| Chrome | Linux | Yes (PipeWire) | Yes | Requires PipeWire audio backend |
| Firefox | All | No | Yes (tab only) | Only captures tab audio, not window/screen |
| Safari | macOS | No | No | No audio capture support in screen share |
| Edge | Windows | Yes | Yes | Same engine as Chrome |

### Voice Controls Bar

The voice controls bar persists across text channel navigation (it is not inside the Turbo Frame). It renders at the bottom of the sidebar, above the user panel:

```erb
<!-- app/views/layouts/_voice_controls.html.erb -->
<div id="voice-controls-bar" class="hidden border-t border-gray-700 p-2"
     data-controller="voice-channel">
  <div class="flex items-center justify-between">
    <div class="flex flex-col min-w-0">
      <span class="text-xs font-medium text-green-400 truncate">Voice Connected</span>
      <span class="text-xs text-gray-400 truncate" data-voice-channel-target="channelName"></span>
    </div>
    <div class="flex items-center gap-1">
      <button data-action="voice-channel#toggleMute" title="Mute">
        <!-- microphone icon -->
      </button>
      <button data-action="voice-channel#toggleDeafen" title="Deafen">
        <!-- headphone icon -->
      </button>
      <button data-action="voice-channel#disconnect" title="Disconnect" class="text-red-400">
        <!-- phone-off icon -->
      </button>
    </div>
  </div>
</div>
```

---

## 10. Moderation Flows

### Self-Mute

```
User clicks mute button
  │
  ├─► voice_channel_controller.js
  │     localParticipant.setMicrophoneEnabled(false)
  │     ── audio track disabled locally, no server round-trip for media
  │
  ├─► PATCH /voice_states/self_mute { self_mute: true }
  │     ── Rails updates VoiceState record
  │
  ├─► ServerChannel.broadcast_to(server, { type: "voice_state_update", action: "updated" })
  │     ── all sidebar controllers update the mute icon
  │
  └─► LiveKit receives track mute via WebRTC signaling
        ── stops forwarding audio packets to other participants
```

### Server-Mute (Moderator Action)

```
Moderator right-clicks user → "Server Mute"
  │
  ├─► POST /servers/:id/voice/mute_member { user_id: "..." }
  │     ── Rails checks authorize(@server, :mute_voice_member?)
  │     ── returns 403 if permission denied
  │
  ├─► LivekitRoomService#mute_participant
  │     ── calls RoomServiceClient#mute_published_track
  │     ── LiveKit force-mutes the participant's audio track
  │
  ├─► LiveKit fires track_muted webhook → LivekitWebhooksController
  │     ── updates VoiceState: server_mute: true
  │
  ├─► ServerChannel.broadcast_to(server, { type: "voice_state_update" })
  │     ── sidebar shows server-mute icon on the user
  │
  └─► Muted user's livekit-client receives TrackMuted event
        ── UI updates to show "You have been server muted"
        ── User cannot unmute until a moderator removes the server mute
```

### Self-Deafen

```
User clicks deafen button
  │
  ├─► voice_channel_controller.js
  │     ── disables all remote audio track playback locally
  │     ── also disables own microphone (mute on deafen)
  │     ── purely client-side audio disable, no SFU involvement
  │
  ├─► PATCH /voice_states/self_deafen { self_deaf: true }
  │     ── Rails updates VoiceState record
  │
  └─► ServerChannel.broadcast_to(server, { type: "voice_state_update" })
        ── sidebar shows deafen icon on the user
```

### Server-Deafen (Moderator Action)

```
Moderator right-clicks user → "Server Deafen"
  │
  ├─► POST /servers/:id/voice/deafen_member { user_id: "..." }
  │     ── Rails checks authorize(@server, :deafen_voice_member?)
  │
  ├─► LivekitRoomService#update_participant_permissions
  │     ── sets can_subscribe: false
  │     ── LiveKit revokes the participant's ability to receive tracks
  │
  ├─► VoiceState.update!(server_deaf: true)
  │
  └─► ServerChannel.broadcast_to(server, { type: "voice_state_update" })
        ── user sees "You have been server deafened"
        ── user cannot hear any participants until moderator removes it
```

### Move Member

```
Moderator right-clicks user → "Move to #voice-2"
  │
  ├─► POST /servers/:id/voice/move_member { user_id: "...", target_channel_id: "..." }
  │     ── Rails checks authorize(@server, :move_voice_member?)
  │     ── checks target channel exists and is voice type
  │
  ├─► LivekitRoomService#remove_participant(channel: source, user_public_id: user.public_id)
  │     ── kicks user from current LiveKit room
  │
  ├─► LiveKit fires participant_left webhook
  │     ── VoiceState destroyed, broadcast sent
  │
  ├─► Rails sends a move instruction via ActionCable (NotificationChannel or ServerChannel)
  │     { type: "voice_move", target_channel_id: "...", token: "new_jwt_token" }
  │
  └─► User's voice_channel_controller receives the move instruction
        ── auto-connects to the new room with the provided token
        ── LiveKit fires participant_joined webhook
        ── new VoiceState created, broadcast sent
```

---

## 11. Scaling & Performance

### LiveKit Official Benchmarks

Tested on a 16-core `c2-standard-16` GCP instance:

| Scenario | Configuration | CPU Usage |
|---|---|---|
| Audio-only room | 10 speakers + 3,000 listeners | ~80% |
| Video meeting | 150 bidirectional 720p streams | ~85% |
| Livestream | 1 publisher → 3,000 viewers | ~92% |

### Self-Hosted Resource Estimates

| Tier | Hardware | Concurrent Voice Users | Notes |
|---|---|---|---|
| Small | 2 cores, 4 GB RAM | ~50 | Suitable for a personal or small community instance |
| Medium | 4 cores, 8 GB RAM | ~200+ | Handles multiple active voice channels simultaneously |
| Large | 16 cores, 32 GB RAM | ~3,000 audio subscribers per room | Production-grade for large communities |

### Multi-Node Clustering

LiveKit supports horizontal scaling for instances that outgrow a single server:

- **Redis coordination** — nodes register and discover each other via Redis. Room state is shared across the cluster.
- **Region-aware routing** — participants are routed to the nearest node. Rooms can span multiple nodes with cascaded forwarding.
- **Graceful draining** — a node marked for maintenance stops accepting new rooms and waits for existing rooms to empty before shutting down.
- **Kubernetes-native** — Helm chart provided. Nodes auto-scale based on CPU/bandwidth metrics.
- **Room affinity** — each room lives on a single node (no split-brain). Unlimited concurrent rooms across the cluster; rooms are distributed automatically.
- **No documented cluster size limit** — LiveKit Cloud runs millions of concurrent connections. Self-hosted ceiling is determined by hardware and Redis throughput.

### How Far Can You Take It

LiveKit Cloud handles millions of concurrent participants and up to 100,000 participants per session. Self-hosted instances scale horizontally by adding nodes — each node adds its full capacity to the cluster. The practical ceiling for self-hosted deployments is hardware budget and Redis throughput, not LiveKit software limits.

For Inferno Chat, a single 2-core node is sufficient for most self-hosted instances. Add nodes only when concurrent voice usage consistently exceeds capacity.

---

## 12. Deployment

### Docker Compose

Add LiveKit alongside the existing Rails services:

```yaml
# docker-compose.yml (additions)
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
  # API key : secret — generate with `livekit-server generate-keys`
  APIxxxxxxx: "secret_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

turn:
  enabled: true
  tls_port: 5349
  # Uses the same TLS certificate as the main service
  cert_file: /etc/livekit/tls/cert.pem
  key_file: /etc/livekit/tls/key.pem

webhook:
  urls:
    - "https://your-instance.com/livekit/webhooks"
  api_key: "APIxxxxxxx"

room:
  empty_timeout: 300       # seconds before empty room is destroyed
  max_participants: 0      # 0 = unlimited (enforced at Rails level instead)

logging:
  level: info
```

### Rails Credentials

```yaml
# config/credentials.yml.enc (additions)
livekit:
  url: "wss://your-instance.com:7880"
  api_key: "APIxxxxxxx"
  api_secret: "secret_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
  webhook_secret: "secret_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
```

### Firewall Ports

| Port | Protocol | Purpose |
|---|---|---|
| 7880 | TCP | LiveKit HTTP API + WebSocket signaling |
| 7881 | TCP | WebRTC over TCP (fallback when UDP is blocked) |
| 50000–60000 | UDP | WebRTC media (audio/video packets) |
| 5349 | TCP | TURN over TLS (firewall traversal for restrictive networks) |

All ports are only needed on the LiveKit server. The Rails server communicates with LiveKit over HTTP (port 7880) on the internal network.

---

## 13. Implementation Phases

### Phase 1: Audio Voice Channels

- Add voice permissions to `DEFAULT_PERMISSIONS` and `PERMISSION_GROUPS`
- Create `voice_states` migration
- Create `VoiceState` model with `HasPublicId`
- Add `LivekitTokenService` and `LivekitRoomService`
- Add `VoiceChannelsController` with `join` action
- Add `LivekitWebhooksController` with `participant_joined`/`participant_left`
- Add `voice_state_update` broadcast type to `ServerChannel`
- Add `voice_state_update` handler to `channel_sidebar_controller.js`
- Update `_channel_item.html.erb` with voice icon and participant list
- Add `voice_channel_controller.js` with join, disconnect, toggleMute, toggleDeafen
- Add persistent voice controls bar to sidebar layout
- Add route for LiveKit webhooks
- Add channel settings for `voice_bitrate` and `voice_user_limit`

**Verification:** User can join a voice channel, see participants in sidebar, mute/unmute, deafen/undeafen, and disconnect. Other users see real-time participant list updates.

### Phase 2: Moderation

- Add `mute_voice_member?`, `deafen_voice_member?`, `move_voice_member?` to `ServerPolicy`
- Add server-side mute/deafen/kick/move endpoints
- Add `VoiceModerationController` with permission-checked actions
- Add right-click context menu options for voice moderation
- Handle `track_published`/`track_unpublished` webhooks for state sync
- Add server-mute and server-deafen visual indicators

**Verification:** Moderator can server-mute, server-deafen, and move members. Permission checks prevent unauthorized users. All state changes propagate in real time.

### Testing Needed

- [ ] Self-deafen: clicking deafen button should mute all incoming audio and disable own mic. Verify server request reaches `/voice_states/self_deafen` and UI updates correctly.
- [ ] Self-deafen undeafen: clicking deafen again should restore incoming audio. User stays muted until they manually unmute.
- [ ] Server-deafen via context menu: moderator right-clicks participant → Server Deafen. Target user should lose all audio.

### Phase 3: Video + Screen Share

- Add `video` and `screen_share` permissions
- Add `video_enabled` column to channels
- Add toggleVideo and shareScreen to `voice_channel_controller.js`
- Add video grid layout component
- Add screen share viewer with fullscreen toggle
- Add channel setting to enable/disable video per channel
- Handle screen share browser compatibility (audio capture varies by OS/browser)

**Verification:** Users can enable video and share screen in voice channels. Video grid displays correctly. Screen share audio works on supported browsers. Channel admins can toggle video on/off per channel.

### Phase 4: Polish

- Add `voice_user_limit` enforcement (deny join when full)
- Add speaking indicators (green ring around avatar) using `ActiveSpeakersChanged` event
- Add connection quality indicator (green/yellow/red dots)
- Add noise suppression toggle (Krisp-style, via LiveKit's built-in noise suppression)
- Add automatic reconnection with exponential backoff
- Add rate limiting on voice join/leave to prevent spam
- Add admin instance config: `voice_enabled`, `max_voice_participants_per_channel`
- Clean up stale `VoiceState` records on server startup (in case of unclean shutdown)

**Verification:** User limits enforced. Speaking indicators visible. Reconnection works after brief network drops. Rate limiting prevents join/leave spam. Stale states cleaned up.

---

## 14. Security, Routes, Libraries & Sources

### Security Considerations

- **Token expiry** — LiveKit JWTs are issued with a short TTL (e.g. 10 minutes). The `livekit-client` SDK handles automatic token refresh via the `RoomEvent.TokenExpired` event, which triggers a fetch for a new token from Rails.
- **Permission scoping** — token grants are derived from the user's role at token generation time. Changing a role mid-session does not retroactively update grants; the user must rejoin.
- **Webhook authentication** — LiveKit signs webhook payloads with the API secret. `LiveKit::WebhookReceiver` verifies the signature before processing.
- **TURN credentials** — LiveKit's built-in TURN server uses short-lived credentials derived from the API secret. No separate TURN credential management needed.
- **Rate limiting** — voice join endpoint should be rate-limited (e.g. 5 joins per minute per user) to prevent abuse.
- **Input validation** — channel IDs and user IDs in voice endpoints must be validated as existing records with proper server membership.

### Routes

```ruby
# config/routes.rb (additions)

# LiveKit webhooks (outside of authenticated scope)
post "/livekit/webhooks", to: "livekit_webhooks#create"

# Nested under servers
resources :servers do
  # Voice channel actions
  scope "voice" do
    post "join/:channel_id", to: "voice_channels#join", as: :voice_join
    delete "leave", to: "voice_channels#leave", as: :voice_leave
    post "mute_member", to: "voice_moderation#mute", as: :voice_mute
    post "unmute_member", to: "voice_moderation#unmute", as: :voice_unmute
    post "deafen_member", to: "voice_moderation#deafen", as: :voice_deafen
    post "undeafen_member", to: "voice_moderation#undeafen", as: :voice_undeafen
    post "move_member", to: "voice_moderation#move", as: :voice_move
  end
end

# Self-state updates (current user only)
patch "voice_states/self_mute", to: "voice_states#self_mute"
patch "voice_states/self_deafen", to: "voice_states#self_deafen"
```

### Library Summary

| Library | Version | Purpose | Install |
|---|---|---|---|
| `livekit-server-sdk` | ~> 0.8 | Token generation, room management, webhook verification | `bundle add livekit-server-sdk` |
| `livekit-client` | ~> 2.x | Browser WebRTC client, room connection, track management | `yarn add livekit-client` / `importmap pin livekit-client` |
| `livekit/livekit-server` | latest | SFU server (Docker image or binary) | `docker pull livekit/livekit-server` |

### Sources

- LiveKit documentation: https://docs.livekit.io
- LiveKit Ruby SDK: https://github.com/livekit/server-sdk-ruby
- LiveKit JavaScript SDK: https://github.com/livekit/client-sdk-js
- LiveKit self-hosting guide: https://docs.livekit.io/realtime/self-hosting/
- LiveKit benchmarks: https://docs.livekit.io/realtime/self-hosting/benchmark/
- WebRTC `getDisplayMedia` spec: https://www.w3.org/TR/screen-capture/
- Janus Gateway: https://janus.conf.meetecho.com
- mediasoup: https://mediasoup.org
- Galene: https://galene.org
- Jitsi Meet: https://jitsi.org
