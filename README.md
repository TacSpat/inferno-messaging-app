# Inferno

**Blazing fast. Hot to the touch.**

Inferno is a chat app that looks and feels like the platforms you already know — servers, channels, voice chat, roles, DMs, all of it — but with one difference: nobody can take it away from you.

Centralized platforms can change their terms whenever they want — require ID verification, harvest your data, ban your community, or shut down entirely. You have no say and no recourse. Inferno exists because your community shouldn't be at the mercy of someone else's policy decisions.

Your account works the same way you're used to: email, password, done. But behind the scenes, Inferno gives you an identity that's actually yours. If a server goes down, you don't start over. Your profile, your friends, and your name move with you — automatically.

Communities on Inferno can connect to each other. You can join a server running on the other side of the world without making a new account. Channels can even open up to people outside of Inferno entirely. It's as open or as private as you want it to be.

## Features

- **Messaging** — text channels, direct messages, file sharing, reactions, custom emoji, GIF search, link previews, @mentions
- **Voice & Video** — voice channels, screen sharing, mute/deafen, moderation controls
- **Servers** — organize channels into categories, invite links, custom icons
- **Roles** — fine-grained permissions, role hierarchy, per-channel overrides
- **Social** — friend requests, blocking, user profiles, online status
- **Identity** — your account is portable across servers, powered by Nostr
- **Federation** — servers on different hosts can connect, and channels can open up beyond Inferno
- **Admin** — usage limits, lockdown controls, suspensions, audit logs, data exports, content retention
- **Mobile** — responsive web UI, with native apps planned via Turbo Native (iOS/Android) and Tauri (desktop)

## Stack

Rails 8.1 / PostgreSQL / Redis / Sidekiq / Hotwire (Turbo + Stimulus) / Tailwind CSS 4 / Devise / Pundit / Active Storage / LiveKit / Nostr / Paper Trail

## Setup

```bash
git clone git@github.com:TacSpat/inferno-messaging-app.git
cd inferno-messaging-app
bundle install && bun install
bin/rails db:setup
bin/dev  # starts Rails :3005, Sidekiq, JS/CSS watchers, strfry relay :7777
```

## Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | Development defaults |
| `REDIS_URL` | Redis connection string | `redis://localhost:6379` |
| `INSTANCE_DOMAIN` | Domain for NIP-05 identifiers and `.well-known` routing | `localhost` |
| `SECRET_KEY_BASE` | Rails secret key | From `credentials.yml.enc` |
| `LIVEKIT_URL` | LiveKit WebSocket URL (optional — enables voice) | `ws://localhost:7880` |
| `LIVEKIT_API_KEY` | LiveKit API key | From credentials |
| `LIVEKIT_API_SECRET` | LiveKit API secret | From credentials |

Instance-level settings (limits, federation mode, retention, lockdown) are configured at `/admin/instance_config` after first login.

### Asset distribution (Blossom)

Profile avatars, banners, server icons, and other assets are uploaded to [Blossom](https://github.com/hzrd149/blossom) servers (content-addressable file hosting via BUD-01). URLs embedded in Nostr events point to Blossom servers, not to the instance itself — so cross-instance asset sharing works without instances being directly reachable by each other.

Default Blossom servers: `blossom.primal.net`, `cdn.satellite.earth`. Configure custom servers in instance settings (`/admin/instance_config` → Blossom server URLs).

**Multi-instance testing:** When running two local instances, both use the same default Blossom servers. No `INSTANCE_DOMAIN` configuration is needed for assets to sync — the relay and Blossom servers handle all cross-instance communication.

## Documentation

| Document | Contents |
|----------|----------|
| [architecture-cross-instance.md](doc/architecture-cross-instance.md) | Federation identity model, auth flow, data boundaries, trust, relay architecture, key management, scaling |
| [roadmap-cross-instance.md](doc/roadmap-cross-instance.md) | 6-phase federation implementation roadmap with migrations, controllers, and verification checklists |
| [voice-video-architecture.md](doc/voice-video-architecture.md) | SFU comparison, LiveKit integration, schema, client JS, moderation flows, deployment |
| [design-trust-compliance-monetization.md](doc/design-trust-compliance-monetization.md) | Audit logging, legal compliance, content safety, trust tiers, rate limiting, API versioning, monetization |
| [roadmap-product.md](doc/roadmap-product.md) | Product roadmap — flagship instance, native apps, hosted offering, growth strategy, revenue model |

## Testing

```bash
bundle exec rspec        # 573 specs
bin/rails test           # Minitest
bin/rails test:system    # System tests
bundle exec rubocop      # Lint
bundle exec brakeman     # Security scan
```

CI runs all of the above on every push via GitHub Actions.

## License

[AGPL-3.0](LICENSE)
