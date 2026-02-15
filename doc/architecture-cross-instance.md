# Cross-Instance Identity & Communication — Architecture

## Overview

This document describes how independent, self-hosted instances of Inferno Chat communicate with each other and how users move between them. The design is a **hybrid** of Devise (local authentication) and Nostr (cross-instance identity and relay-based communication).

Each instance remains a fully self-contained Rails monolith. Nostr is not a replacement for local auth — it is a portable identity layer that lets instances verify who a user is without sharing a database.

---

## 1. Identity Model

### Local Identity (Devise)

Every instance keeps its own `users` table. Devise handles signup, login, email confirmation, and password management exactly as it does today. A user's canonical local identifier remains `username#discriminator` (e.g. `Tac#0420`).

### Cross-Instance Identity (Nostr Keypair)

On signup, the instance auto-generates a Nostr secp256k1 keypair for the user:

| Column | Type | Description |
|--------|------|-------------|
| `nostr_public_key` | `string` | 32-byte hex public key (npub) — the user's global identity |
| `nostr_encrypted_private_key` | `text` | Private key encrypted at rest with the instance's `Rails.application.credentials.secret_key_base` |

The **public key** is the user's cross-instance identifier. Two accounts on different instances with the same public key are the same person.

### NIP-05 Verification

Each instance exposes a `/.well-known/nostr.json` endpoint (NIP-05) that maps local usernames to public keys:

```
GET https://inferno.chat/.well-known/nostr.json?name=tac

{
  "names": {
    "tac": "ab12cd34..."
  }
}
```

This gives every user a human-readable identifier in the form `tac@inferno.chat`, verifiable by any Nostr client or remote instance.

---

## 2. Cross-Instance Authentication

### Flow: Logging Into a Remote Instance

A user has a Devise session on their **home instance** (`home.chat`). They want to join a server on a **remote instance** (`remote.chat`).

```
User                    remote.chat                  home.chat
 │                          │                            │
 ├─ GET /auth/nostr ───────►│                            │
 │                          ├─ Generate challenge ──────►│
 │  ◄── Redirect to ───────┤  (nonce + timestamp)       │
 │      home.chat/auth/                                  │
 │      nostr/sign?                                      │
 │      challenge=...&                                   │
 │      callback=remote.chat                             │
 │                                                       │
 ├─ (User has Devise session on home.chat) ─────────────►│
 │                                                       │
 │                          │  ◄── Signed challenge ─────┤
 │                          │      (Nostr event, kind    │
 │                          │       22242, NIP-42)       │
 │                          │                            │
 │                          ├─ Verify signature          │
 │                          │  against pubkey            │
 │                          ├─ Verify NIP-05:            │
 │                          │  GET home.chat/            │
 │                          │  .well-known/nostr.json    │
 │                          │                            │
 │  ◄── Session created ───┤                            │
 │      (remote user record │                            │
 │       with pubkey)       │                            │
```

**Steps:**

1. User clicks "Login with Home Instance" on `remote.chat`.
2. `remote.chat` generates a challenge (random nonce + timestamp + relay URL) and redirects the user to `home.chat/auth/nostr/sign`.
3. `home.chat` verifies the user has a valid Devise session, then signs the challenge with the user's Nostr private key (creating a NIP-42 `AUTH` event, kind 22242).
4. `home.chat` redirects back to `remote.chat` with the signed event.
5. `remote.chat` verifies the signature against the public key, confirms the pubkey matches via NIP-05 (`home.chat/.well-known/nostr.json`), and creates a local `RemoteUser` record.
6. The user now has a session on `remote.chat`.

### Fallback Authentication

If the user's home instance is down, any instance where the user has an **active session** can vouch for them:

1. `remote.chat` cannot reach `home.chat` for NIP-05 verification.
2. `remote.chat` checks if the user's public key has a cached NIP-05 result (stored with a TTL from a previous successful verification).
3. If not cached, `remote.chat` can accept a vouching flow: another instance where the user is already authenticated (`other.chat`) signs a NIP-42 challenge on the user's behalf.
4. The vouching instance's NIP-05 confirmation of the pubkey serves as secondary proof.

This degrades gracefully — the more instances a user has authenticated with, the more resilient their cross-instance access becomes.

---

## 3. Data Boundaries

### What Stays Local (Rails DB Only)

These are never shared via relays or cross-instance APIs:

| Data | Reason |
|------|--------|
| Messages | Stored in the instance's `messages` table; channels are local to a server |
| Server memberships | `server_memberships` join table is local |
| Roles & permissions | `roles` with JSONB `permissions` — local authority |
| Channel structure | Categories, channels, permission overrides |
| Invites | Invite codes, usage counts, expiry — local |
| Bans | Local `bans` table per server |
| Notifications | Local notification preferences and read state |
| Reactions | Local to the message and channel |
| DM conversations | `conversations` / `conversation_participants` — local |

### What Syncs via Nostr Relays

These are published as Nostr events so remote instances can pull them:

| Data | Nostr Event Kind | Description |
|------|-------------------|-------------|
| Profile metadata | Kind 0 (NIP-01) | Display name, bio, avatar URL, status |
| Contact list | Kind 3 (NIP-02) | Friend links (public keys of friends) |
| Instance list | Kind 10002 (NIP-65) | List of relays/instances a user is associated with |
| Mute/block lists | Kind 10000/30000 (NIP-51) | Public key block lists (shared across instances) |

The sync model is **publish-on-change, pull-on-demand**: when a user updates their profile locally, the instance publishes a Kind 0 event to connected relays. When a remote instance needs a user's profile, it fetches the latest Kind 0 event for that pubkey.

---

## 4. Instance Trust Model

### Default: Open Federation

By default, any instance can authenticate remote users. This mirrors how email works — any server can send to any other.

### Blocklist Model

Admins manage a local **instance blocklist**. Blocked instances are rejected at the authentication layer:

| Column | Type | Description |
|--------|------|-------------|
| `domain` | `string` | The blocked instance's domain (e.g. `spam.chat`) |
| `reason` | `text` | Admin-provided reason for the block |
| `blocked_by_id` | `bigint` | Admin who added the block |
| `blocked_at` | `datetime` | When the block was created |

When a remote auth request comes from a blocked domain, the instance rejects it immediately. Existing sessions from blocked instances are revoked.

### Invite-Only Joining

Server owners can require invites for remote users, just as they already can for local users. The existing `Invite` model (with `code`, `max_uses`, `uses_count`, `expires_at`, `active`) works unchanged — remote users accept invites the same way local users do, after completing cross-instance auth.

### Lockdown Mode

For raids or abuse scenarios, admins can enable **lockdown mode** at the instance level:

- All new remote authentications are paused.
- Existing remote sessions remain valid.
- New local signups can optionally be paused.
- Lockdown is toggled via an admin setting, not a code change.

---

## 5. Remote Users

### Remote User Record

When a remote user authenticates, the instance creates a local record:

| Column | Type | Description |
|--------|------|-------------|
| `nostr_public_key` | `string` | The user's global public key |
| `home_instance` | `string` | Domain of the user's home instance |
| `display_name` | `string` | Pulled from Nostr Kind 0 profile |
| `avatar_url` | `string` | Pulled from Nostr Kind 0 profile |
| `bio` | `text` | Pulled from Nostr Kind 0 profile |
| `last_verified_at` | `datetime` | Last successful NIP-05 verification |
| `remote` | `boolean` | `true` — distinguishes from local users |

### Permissions

Remote users receive the **same default permissions** as local users. On joining a server, they are assigned the `@everyone` role like any new member. Server admins can:

- Assign roles to remote users (promote to moderator, etc.).
- Kick or ban remote users from individual servers.
- Instance admins can ban a remote user's public key across all servers.
- Instance admins can block an entire remote instance (see blocklist above).

There is no automatic permission reduction for remote users. Trust is symmetric by default.

---

## 6. Relay Architecture

### Instance Relay (Optional Sidecar)

Each instance can optionally run a **strfry** relay as a sidecar process:

```
┌─────────────────────────────────┐
│  Instance (e.g. inferno.chat)   │
│                                 │
│  ┌───────────┐  ┌────────────┐  │
│  │  Rails     │  │  strfry    │  │
│  │  (Puma)    │◄─┤  relay     │  │
│  │            │  │  (ws://)   │  │
│  └─────┬─────┘  └─────┬──────┘  │
│        │              │          │
│  ┌─────▼─────┐        │          │
│  │ PostgreSQL │        │          │
│  └───────────┘        │          │
└───────────────────────┼──────────┘
                        │
              ┌─────────▼──────────┐
              │  Public Nostr      │
              │  Relays            │
              │  (relay.damus.io,  │
              │   nos.lol, etc.)   │
              └────────────────────┘
```

**The relay's role:**

- Publishes profile (Kind 0) and contact (Kind 3) events for local users.
- Subscribes to profile events for remote users the instance cares about.
- Federates with public Nostr relays so profiles are discoverable outside the instance's own relay.
- Instances without their own relay can use public relays directly.

### What Flows Through Relays

| Event Kind | NIP | Purpose |
|------------|-----|---------|
| Kind 0 | NIP-01 | Profile metadata (name, about, picture) |
| Kind 3 | NIP-02 | Contact/friend list |
| Kind 10002 | NIP-65 | Relay list (which relays the user publishes to) |
| Kind 10000 | NIP-51 | Mute list |
| Kind 30000 | NIP-51 | Categorized people lists (block lists) |
| Kind 9, 10, 11, 12 | NIP-29 | Group chat events (Phase 5 — shared channels) |
| Kind 22242 | NIP-42 | Relay authentication challenges |
| Kind 1059 | NIP-44 | Encrypted direct messages (future) |
| Kind 24133 | NIP-46 | Remote signing requests (advanced key management) |

---

## 7. Key Management

### Default: Custodial (Instance-Managed)

The instance is the **custodial key manager**. This is the experience for most users:

- Keypair is generated on signup using `secp256k1`.
- Private key is encrypted with `Rails.application.credentials.secret_key_base` and stored in the database.
- The user never needs to see or manage their keys.
- The instance signs Nostr events on the user's behalf.

### Advanced: Key Export/Import

Power users can take control of their keys:

**Export:**
- User can view and copy their `nsec` (private key in bech32 format) from account settings.
- This allows them to use their identity in standalone Nostr clients.

**Import (NIP-07 Browser Extension):**
- Users with a NIP-07–compatible browser extension (nos2x, Alby, etc.) can link their existing Nostr identity.
- On signup or in settings, the instance detects the extension and requests the public key.
- The instance stores only the public key; signing is delegated to the extension.
- For server-side signing (e.g., publishing profile events), the instance uses NIP-46 remote signing to request signatures from the user's extension/signer.

**Key Recovery:**
- If a user loses access to their home instance, their exported `nsec` lets them re-establish identity on a new instance.
- The new instance generates an account, the user imports their key, and remote instances can verify continuity via the same public key.

---

## 8. Relevant NIPs Reference

| NIP | Title | Usage |
|-----|-------|-------|
| [NIP-01](https://github.com/nostr-protocol/nips/blob/master/01.md) | Basic Protocol | Event format, Kind 0/1/3, relay communication |
| [NIP-05](https://github.com/nostr-protocol/nips/blob/master/05.md) | DNS-Based Verification | `user@instance.com` identifiers via `/.well-known/nostr.json` |
| [NIP-07](https://github.com/nostr-protocol/nips/blob/master/07.md) | Browser Extension | `window.nostr` API for key management in browser extensions |
| [NIP-29](https://github.com/nostr-protocol/nips/blob/master/29.md) | Relay-Based Groups | Cross-instance shared channels (Phase 5) |
| [NIP-42](https://github.com/nostr-protocol/nips/blob/master/42.md) | Relay Authentication | Challenge-response auth, Kind 22242 events |
| [NIP-44](https://github.com/nostr-protocol/nips/blob/master/44.md) | Encrypted Payloads | End-to-end encrypted DMs and key backup |
| [NIP-46](https://github.com/nostr-protocol/nips/blob/master/46.md) | Remote Signing | Delegate signing to browser extensions or external signers |
| [NIP-49](https://github.com/nostr-protocol/nips/blob/master/49.md) | Encrypted Private Key | Password-encrypted key export (ncryptsec) |
| [NIP-51](https://github.com/nostr-protocol/nips/blob/master/51.md) | Lists | Mute lists, block lists, categorized people lists |
| [NIP-56](https://github.com/nostr-protocol/nips/blob/master/56.md) | Reporting | Flagging content/users for moderation |
| [NIP-65](https://github.com/nostr-protocol/nips/blob/master/65.md) | Relay List Metadata | Kind 10002 — which relays a user reads/writes to |

---

## 9. Instance Scaling & Resource Limits

### Horizontal Scaling

A single Inferno Chat instance (one domain) can run across multiple machines:

```
                    ┌─────────────────────┐
                    │   Load Balancer      │
                    │  (nginx / HAProxy)   │
                    └────┬───────┬─────────┘
                         │       │
                  ┌──────┴──┐ ┌──┴──────┐
                  │  Puma 1  │ │  Puma 2  │   ← stateless, scale out freely
                  └────┬─────┘ └──┬──────┘
                       │          │
                  ┌────┴──────────┴────┐
                  │   Redis Cluster    │   ← ActionCable pub/sub + Sidekiq queues
                  └────┬──────────┬────┘
                       │          │
                ┌──────┴──┐ ┌────┴──────┐
                │Sidekiq 1│ │ Sidekiq 2 │   ← job workers, scale out freely
                └─────────┘ └───────────┘

                  ┌────────────────────┐
                  │  PostgreSQL Primary │
                  ├────────────────────┤
                  │  Read Replica 1    │   ← Rails multi-DB (built-in since 6.0)
                  │  Read Replica 2    │
                  └────────────────────┘

                  ┌────────────────────┐
                  │  S3 / MinIO        │   ← Active Storage, scales infinitely
                  └────────────────────┘
```

**Works out of the box:**
- **Puma** — stateless web servers behind a load balancer
- **Sidekiq** — multiple workers sharing a Redis queue
- **Active Storage** — swap local disk for S3/MinIO
- **ActionCable** — Redis adapter for pub/sub across Puma instances

**With configuration only:**
- **Read replicas** — Rails `connects_to` in `database.yml`
- **Connection pooling** — PgBouncer in front of PostgreSQL

**For very large instances:**
- **Database sharding** — Rails 6.1+ built-in shard support; natural shard key is `server_id` since most queries are server-scoped

### Instance Resource Limits

Instance admins configure limits via the admin UI (`/admin/instance_config`):

| Setting | Default | Description |
|---------|---------|-------------|
| `max_users` | 0 (unlimited) | Total user registrations |
| `max_servers` | 0 (unlimited) | Total servers on instance |
| `max_servers_per_user` | 5 | Servers a user can create |
| `max_channels_per_server` | 50 | Channels per server |
| `max_categories_per_server` | 20 | Categories per server |
| `max_members_per_server` | 0 (unlimited) | Members per server |
| `max_roles_per_server` | 25 | Roles per server |
| `max_upload_size_mb` | 25 | Per-file upload limit |
| `max_storage_per_user_mb` | 0 (unlimited) | Total storage per user |

Limits are enforced at model creation time via validations. When a limit is reached, the user sees a clear error message.

### Message Pruning

Configurable via admin UI with three strategies:

- **None** — keep everything forever (default)
- **Time-based** — delete messages older than N days
- **Storage-based** — prune attachments first (free storage), then prune message text

Additional options:
- Separate retention periods for messages vs attachments (attachments are storage-expensive, text is cheap)
- Pinned messages can be excluded from pruning
- Pruning runs as a Sidekiq job (`PruneMessagesJob`), triggered via `rake maintenance:prune` on a cron schedule

### Instance Discovery

Each instance exposes `/.well-known/instance.json` with its name, description, limits, and current usage. This lets users browse instances and pick one based on capacity and community before joining.

---

## 10. Security Considerations

### Challenge Replay Prevention
- Auth challenges include a nonce, timestamp, and the requesting relay/instance URL.
- Challenges expire after 5 minutes.
- Each challenge can only be used once (tracked server-side).

### NIP-05 Cache Poisoning
- NIP-05 responses are cached with a TTL (e.g. 1 hour) and re-verified periodically.
- The cache is invalidated on any authentication failure for that pubkey.
- HTTPS is required for all NIP-05 lookups.

### Key Encryption at Rest
- Private keys are encrypted using AES-256-GCM with a key derived from `secret_key_base`.
- The encrypted key is never exposed via API responses.
- Key export requires the user's current password as confirmation.

### Rate Limiting
- Remote auth endpoints are rate-limited per source IP and per domain.
- Lockdown mode provides a circuit breaker for abuse scenarios.

### Relay Event Validation
- All incoming Nostr events are validated: signature check, schema check, timestamp bounds.
- Events from blocked instances' pubkeys are dropped.
