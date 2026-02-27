# Inferno — Current Plan

## Architecture

Inferno is a single-binary Rails chat app backed by SQLite. All communication (messages, DMs, server state, profiles, presence) flows through Nostr relays. The local database is a cache; relays are the source of truth.

**Stack:** Rails 8.1 / SQLite / Solid Queue / Hotwire / Tailwind CSS 4 / Bun / Devise / LiveKit / Nostr

**Key NIPs:** NIP-01, NIP-05, NIP-24, NIP-29, NIP-42, NIP-44, NIP-49, NIP-59

## What's Built

- Full messaging: text channels, DMs, file sharing, reactions, custom emoji/stickers, GIF search, link previews, @mentions
- Voice & video: LiveKit SFU, screen sharing, moderation controls
- Servers: categories, nested channels, invite links, custom icons
- Roles: 30+ permissions, hierarchy, per-channel overrides
- Social: friend requests, blocking, profiles, presence (Online/Idle/DnD/Invisible)
- Nostr identity: auto keypair, NIP-05, key export (NIP-49), profile sync (Kind 0)
- Relay-bound: all server state (Kinds 31750–31757), messages (Kind 9), DMs (Kind 14), presence (Kind 30315)
- Encrypted channels: NIP-44 (XChaCha20-Poly1305)
- Remote members: tracked by pubkey, profiles from relays, role assignment
- Admin: usage limits, lockdown, suspensions, audit logs, exports, retention
- Asset distribution: Blossom (BUD-01) content-addressable file hosting

## What's Next

See [doc/roadmap.md](doc/roadmap.md) for technical details and [doc/roadmap-product.md](doc/roadmap-product.md) for product strategy.

### Near-term
- Native apps (Turbo Native iOS/Android, Tauri desktop)
- E2E encrypted DMs (NIP-44 client-side)
- Server discovery via relay metadata events
- Single-binary packaging (Tebako)

### Medium-term
- Monetization (Stripe + Lightning Zaps)
- Verification badges
- Content safety pipeline (CSAM scanning, NCMEC reporting)
- Full-text message search
- Bots & integrations API
