# Inferno

**Blazing fast. Hot to the touch.**

Inferno is a chat app that looks and feels like the platforms you already know — servers, channels, voice chat, roles, DMs, all of it — but with one difference: nobody can take it away from you.

Centralized platforms can change their terms whenever they want — require ID verification, harvest your data, ban your community, or shut down entirely. You have no say and no recourse. Inferno exists because your community shouldn't be at the mercy of someone else's policy decisions.

Your account works the same way you're used to: email, password, done. But behind the scenes, Inferno gives you an identity that's actually yours — a Nostr keypair that makes your profile, friends, and servers portable. Everything syncs through Nostr relays, so your data lives where you put it, not where a corporation decides.

## Features

- **Messaging** — text channels, direct messages, file sharing, reactions, custom emoji/stickers, GIF search, link previews, @mentions
- **Voice & Video** — voice channels, screen sharing, mute/deafen, moderation controls (LiveKit)
- **Servers** — organize channels into categories, invite links, custom icons, nested channels
- **Roles** — fine-grained permissions (30+), role hierarchy, per-channel overrides
- **Social** — friend requests, blocking, user profiles, online status with manual status picker (Online/Idle/DnD/Invisible)
- **Identity** — Nostr keypair generated on signup, NIP-05 verification, key export (NIP-49), portable across any Nostr client
- **Relay-Bound** — all server state, messages, DMs, and profiles sync through Nostr relays — no direct instance-to-instance communication
- **Encrypted Channels** — NIP-44 (XChaCha20-Poly1305) encryption for private channels
- **Admin** — usage limits, lockdown controls, suspensions, audit logs, data exports, content retention
- **Mobile** — responsive web UI

## Stack

Rails 8.1 / SQLite / Solid Queue / Hotwire (Turbo + Stimulus) / Tailwind CSS 4 / Bun / Devise / Active Storage / LiveKit / Nostr (NIP-01, NIP-05, NIP-29, NIP-42, NIP-44, NIP-49)

## How It Works

Inferno is a single-binary Rails app backed by SQLite. All communication flows through Nostr relays:

```
┌──────────────────────────┐
│  Inferno (single binary) │
│                          │
│  Rails 8.1 (Puma)        │
│  SQLite (all app data)   │
│  Solid Queue (jobs)      │
│  strfry (Nostr relay)    │
│  LiveKit (voice/video)   │
│                          │
│       ▲ WebSocket ▼      │
└───────┼──────────┼───────┘
        │          │
  ┌─────▼──────────▼─────┐
  │   Nostr Relays        │
  │   (relay.damus.io,    │
  │    nos.lol, etc.)     │
  └───────────────────────┘
```

**Server state** (channels, roles, members, emojis, stickers, bans, invites) is published as replaceable Nostr events (Kinds 31750–31757). **Messages** flow as NIP-29 group chat events (Kind 9). **DMs** use Kind 14 with NIP-44 encryption. **Profiles** sync via Kind 0. **Presence** broadcasts via Kind 30315.

The local SQLite database is a cache — the relay is the source of truth.

### Asset Distribution (Blossom)

Profile avatars, banners, server icons, and file attachments are uploaded to [Blossom](https://github.com/hzrd149/blossom) servers (content-addressable file hosting via BUD-01). URLs embedded in Nostr events point to Blossom servers, so assets are accessible from anywhere.

Default Blossom servers: `blossom.primal.net`, `cdn.satellite.earth`. Configurable in server settings.

## Setup

```bash
git clone git@github.com:TacSpat/inferno-messaging-app.git
cd inferno-messaging-app
bundle install && bun install
bin/rails db:setup
bin/dev  # starts Rails :3005, JS/CSS watchers, strfry relay :7777
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `SECRET_KEY_BASE` | Rails secret key | From `credentials.yml.enc` |
| `INSTANCE_DOMAIN` | Domain for NIP-05 identifiers | `localhost` |
| `LIVEKIT_URL` | LiveKit WebSocket URL (optional — enables voice) | `ws://localhost:7880` |
| `LIVEKIT_API_KEY` | LiveKit API key | From credentials |
| `LIVEKIT_API_SECRET` | LiveKit API secret | From credentials |

Server-level settings (limits, retention, lockdown) are configured in the admin UI after first login.

## Nostr Protocol Usage

| Event Kind | NIP | Purpose |
|------------|-----|---------|
| Kind 0 | NIP-01 | User profiles (name, bio, avatar) |
| Kind 7 | NIP-25 | Reactions on messages |
| Kind 9 | NIP-29 | Group chat messages |
| Kind 14 | NIP-24 | Direct messages |
| Kind 1059 | NIP-59 | Gift-wrapped (encrypted) DMs |
| Kind 9005 | NIP-29 | Message deletion |
| Kind 22242 | NIP-42 | Relay authentication |
| Kind 25050 | — | Typing indicators (ephemeral) |
| Kind 30315 | — | Online presence / status |
| Kind 31750–31757 | — | Server state (metadata, channels, roles, members, emojis, stickers, bans, invites) |

## Documentation

| Document | Contents |
|----------|----------|
| [architecture.md](doc/architecture.md) | Relay-bound architecture, identity model, data flow, key management, NIPs reference |
| [roadmap.md](doc/roadmap.md) | Implementation roadmap — what's built, what's next |
| [voice-video-architecture.md](doc/voice-video-architecture.md) | LiveKit integration, voice channels, moderation, deployment |
| [design-trust-compliance-monetization.md](doc/design-trust-compliance-monetization.md) | Audit logging, content safety, rate limiting, monetization |
| [roadmap-product.md](doc/roadmap-product.md) | Product roadmap — native apps, monetization, growth |

## Testing

```bash
bundle exec rspec        # RSpec specs
bin/rails test           # Minitest
bin/rails test:system    # System tests
bundle exec rubocop      # Lint
bundle exec brakeman     # Security scan
```

## License

[Elastic License 2.0](LICENSE)
