# Inferno Chat

A self-hosted messaging platform built with Rails 8. Supports servers with channels, direct messages, roles and permissions, friend/block lists, and cross-instance federation via Nostr.

## Stack

- **Backend:** Ruby on Rails 8, PostgreSQL, Sidekiq, ActionCable
- **Frontend:** Hotwire (Turbo + Stimulus), Tailwind CSS
- **Auth:** Devise 5 (email/password + email confirmation)
- **Storage:** Active Storage (avatars, banners, file attachments)
- **Identity:** Nostr keypairs for cross-instance identity (NIP-05 verification)

## Requirements

- Ruby 3.4+
- PostgreSQL 14+
- Redis (for Sidekiq + ActionCable)
- Node.js 20+ / Bun (for JS bundling)

## Setup

```bash
git clone git@github.com:TacSpat/inferno-messaging-app.git
cd inferno-messaging-app
bundle install
bun install

bin/rails db:setup
bin/rails nostr:backfill_keys  # generate Nostr keypairs for existing users

bin/dev  # starts Rails, Sidekiq, and JS/CSS watchers
```

## Configuration

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `DATABASE_URL` | PostgreSQL connection string | development defaults |
| `REDIS_URL` | Redis connection string | `redis://localhost:6379` |
| `INSTANCE_DOMAIN` | Domain for NIP-05 identifiers | `localhost` |

## Features

- **Servers & Channels** — Create servers with text/voice/announcement channels organized in categories
- **Roles & Permissions** — JSONB-based role system with 15 permission flags and hierarchy
- **Direct Messages** — 1:1 conversations with message request acceptance
- **Friends & Blocks** — Bidirectional friend requests, unilateral blocking
- **Invites** — Invite codes with expiry, max uses, and revocation
- **Real-time** — ActionCable for live messages, typing indicators, presence
- **Nostr Identity** — Every user gets a secp256k1 keypair; NIP-05 verification at `/.well-known/nostr.json`

## Cross-Instance Federation

See [doc/architecture-cross-instance.md](doc/architecture-cross-instance.md) for the architecture and [doc/roadmap-cross-instance.md](doc/roadmap-cross-instance.md) for the implementation roadmap.

## License

Private — all rights reserved.
