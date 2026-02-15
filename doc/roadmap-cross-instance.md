# Cross-Instance Identity & Communication — Implementation Roadmap

Each phase is independently deployable. Phase 1 adds value on its own (portable identity), and each subsequent phase builds on the previous without requiring later phases to be useful.

---

## Phase 1: Foundation — Nostr Keypairs & NIP-05

**Goal:** Every user gets a Nostr identity. The instance becomes a NIP-05 provider. Keys can be exported.

### Models & Migrations

**Migration: `AddNostrKeysToUsers`**
```ruby
add_column :users, :nostr_public_key, :string
add_column :users, :nostr_encrypted_private_key, :text
add_index :users, :nostr_public_key, unique: true
```

**User model changes:**
- Add `after_create :generate_nostr_keypair` callback.
- Add `nostr_public_key` and `nostr_private_key` (decrypted accessor) methods.
- Private key encryption uses `ActiveSupport::MessageEncryptor` with a key derived from `Rails.application.credentials.secret_key_base`.

**Backfill task:**
```ruby
# lib/tasks/nostr.rake
namespace :nostr do
  desc "Generate Nostr keypairs for existing users"
  task backfill_keys: :environment do
    User.where(nostr_public_key: nil).find_each do |user|
      user.generate_nostr_keypair
      user.save!
    end
  end
end
```

### Gems & Libraries

| Gem/Library | Purpose |
|-------------|---------|
| `nostr_ruby` | Secp256k1 key generation, event creation, event signing |

Add to `Gemfile`:
```ruby
gem "nostr_ruby"
```

### Controllers & Endpoints

**`Nostr::WellKnownController`** — NIP-05 JSON endpoint:
```
GET /.well-known/nostr.json?name=tac

Response:
{
  "names": {
    "tac": "<hex_pubkey>"
  },
  "relays": {
    "<hex_pubkey>": ["wss://relay.inferno.chat"]
  }
}
```

Route:
```ruby
get "/.well-known/nostr.json", to: "nostr/well_known#show"
```

**Key export UI** — Add a section to user settings (`/settings/account`):
- Display the user's `npub` (bech32-encoded public key).
- "Export Private Key" button → requires password confirmation → displays `nsec`.
- "Import Key" option → accept an `nsec` or connect via NIP-07 browser extension.

### Verification

- [ ] New users get a keypair on signup.
- [ ] Existing users get keypairs via `rake nostr:backfill_keys`.
- [ ] `GET /.well-known/nostr.json?name=<username>` returns the correct pubkey.
- [ ] NIP-05 response passes validation at [nostr.directory](https://nostr.directory) or `nostr_ruby` client.
- [ ] Key export shows correct `nsec`; reimporting it on another instance produces the same `npub`.

---

## Phase 2: Instance Discovery & Trust

**Goal:** Instances can advertise themselves and admins can control which remote instances are trusted.

### Models & Migrations

**Migration: `CreateInstanceBlocklists`**
```ruby
create_table :instance_blocklists do |t|
  t.string :domain, null: false
  t.text :reason
  t.references :blocked_by, null: false, foreign_key: { to_table: :users }
  t.datetime :blocked_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
  t.timestamps
end

add_index :instance_blocklists, :domain, unique: true
```

**Migration: `AddInstanceSettings`**
```ruby
# Store instance-level federation settings in a settings table or Rails credentials
create_table :instance_settings do |t|
  t.string :key, null: false
  t.text :value
  t.timestamps
end

add_index :instance_settings, :key, unique: true
```

Settings keys:
- `federation_mode`: `"open"` (default), `"allowlist"`, `"closed"`
- `lockdown_enabled`: `"false"` (default)
- `instance_relay_url`: `"wss://relay.inferno.chat"` (optional)
- `instance_display_name`: `"Inferno Chat"`
- `instance_description`: short description for discovery

### Controllers & Endpoints

**Instance metadata endpoint:**
```
GET /.well-known/instance.json

{
  "name": "Inferno Chat",
  "description": "A self-hosted messaging community",
  "domain": "inferno.chat",
  "federation_mode": "open",
  "relay": "wss://relay.inferno.chat",
  "nostr_pubkey": "<instance_pubkey>",
  "version": "1.0.0"
}
```

Route:
```ruby
get "/.well-known/instance.json", to: "nostr/instance_metadata#show"
```

**Admin UI — Instance Management** (`/admin/instances`):
- List known remote instances (populated as remote users authenticate).
- Block/unblock instances with a reason.
- Toggle federation mode (open / allowlist / closed).
- Toggle lockdown mode.

Routes:
```ruby
namespace :admin do
  resources :instances, only: [:index, :show] do
    member do
      post :block
      delete :unblock
    end
  end
  resource :federation_settings, only: [:show, :update]
end
```

### Gems & Libraries

No new gems required.

### Verification

- [ ] `GET /.well-known/instance.json` returns correct metadata.
- [ ] Admin can add a domain to the blocklist.
- [ ] Admin can remove a domain from the blocklist.
- [ ] Blocklist entries persist and are queryable by domain.
- [ ] Federation mode setting is persisted and readable.
- [ ] Lockdown toggle works and is reflected in instance metadata.

---

## Phase 3: Cross-Instance Authentication

**Goal:** Users can authenticate on remote instances using their home instance's Devise session and Nostr keypair.

### Models & Migrations

**Migration: `CreateRemoteUsers`**
```ruby
create_table :remote_users do |t|
  t.string :nostr_public_key, null: false
  t.string :home_instance, null: false
  t.string :display_name
  t.string :avatar_url
  t.text :bio
  t.string :username
  t.datetime :last_verified_at
  t.string :public_id, limit: 12
  t.timestamps
end

add_index :remote_users, :nostr_public_key, unique: true
add_index :remote_users, :public_id, unique: true
add_index :remote_users, :home_instance
```

**Migration: `CreateNostrAuthChallenges`**
```ruby
create_table :nostr_auth_challenges do |t|
  t.string :nonce, null: false
  t.string :requesting_domain, null: false
  t.string :callback_url, null: false
  t.datetime :expires_at, null: false
  t.boolean :used, default: false
  t.timestamps
end

add_index :nostr_auth_challenges, :nonce, unique: true
```

**Migration: `CreateNip05Cache`**
```ruby
create_table :nip05_caches do |t|
  t.string :identifier, null: false  # e.g. "tac@home.chat"
  t.string :public_key, null: false
  t.datetime :verified_at, null: false
  t.datetime :expires_at, null: false
  t.timestamps
end

add_index :nip05_caches, :identifier, unique: true
add_index :nip05_caches, :public_key
```

**Polymorphic memberships (optional):**

To let remote users join servers, `ServerMembership` needs to accept both `User` and `RemoteUser`. Two approaches:

- **Option A:** Make `ServerMembership.user` polymorphic (`userable_type` + `userable_id`).
- **Option B:** Give `RemoteUser` a `user_id` FK pointing to a shadow `User` record (with `remote: true` flag).

Option B is simpler — it reuses all existing membership/role/permission logic without changing every query. The `User` model gains a `remote` boolean column and an optional `remote_user_id` FK:

```ruby
add_column :users, :remote, :boolean, default: false
add_reference :users, :remote_user_detail, foreign_key: { to_table: :remote_users }
```

### Controllers & Endpoints

**`Nostr::AuthController`** (on the **remote** instance — the one requesting auth):

```ruby
# GET /auth/nostr — Start remote auth flow
# Generates challenge, redirects to home instance
def new
  challenge = NostrAuthChallenge.create!(
    nonce: SecureRandom.hex(32),
    requesting_domain: request.host,
    callback_url: nostr_auth_callback_url,
    expires_at: 5.minutes.from_now
  )
  redirect_to "#{params[:home_instance]}/auth/nostr/sign?challenge=#{challenge.nonce}&callback=#{challenge.callback_url}",
              allow_other_host: true
end

# GET /auth/nostr/callback — Receive signed challenge
# Verifies signature, creates remote user, starts session
def callback
  # ... verify signature, check NIP-05, create/update remote user
end
```

**`Nostr::SigningController`** (on the **home** instance — the one signing):

```ruby
# GET /auth/nostr/sign — Sign a challenge for a remote instance
# Requires active Devise session
def show
  authenticate_user!
  # Display confirmation: "remote.chat wants to verify your identity"
end

# POST /auth/nostr/sign — Execute the signing
def create
  authenticate_user!
  event = build_nip42_auth_event(
    challenge: params[:challenge],
    relay: params[:callback]
  )
  signed_event = sign_with_user_key(current_user, event)
  redirect_to "#{params[:callback]}?event=#{Base64.urlsafe_encode64(signed_event.to_json)}",
              allow_other_host: true
end
```

Routes:
```ruby
namespace :nostr do
  # Remote instance endpoints
  get  "auth/nostr",          to: "auth#new",      as: :nostr_auth
  get  "auth/nostr/callback", to: "auth#callback",  as: :nostr_auth_callback

  # Home instance endpoints
  get  "auth/nostr/sign",     to: "signing#show"
  post "auth/nostr/sign",     to: "signing#create"
end
```

### Gems & Libraries

| Gem/Library | Purpose |
|-------------|---------|
| `nostr_ruby` | Event creation, signing, signature verification (already added in Phase 1) |

### Verification

- [ ] User on `home.chat` can initiate auth flow to `remote.chat`.
- [ ] `home.chat` signs the challenge only if the user has an active Devise session.
- [ ] `remote.chat` correctly verifies the Nostr signature.
- [ ] `remote.chat` confirms pubkey via NIP-05 lookup to `home.chat`.
- [ ] A `RemoteUser` record is created on `remote.chat` with the correct pubkey and home instance.
- [ ] A shadow `User` record is created so the remote user can join servers.
- [ ] Challenge replay is rejected (nonce reuse, expiry).
- [ ] Auth from a blocked instance is rejected.
- [ ] Fallback: cached NIP-05 is used when home instance is unreachable.

---

## Phase 4: Profile Sync via Relays

**Goal:** Profile changes propagate across instances via Nostr relay events. Remote user profiles stay up to date.

### Models & Migrations

**Migration: `AddRelayTrackingToUsers`**
```ruby
add_column :users, :nostr_profile_published_at, :datetime
add_column :users, :nostr_contacts_published_at, :datetime
```

**Migration: `CreateRelayConnections`**
```ruby
create_table :relay_connections do |t|
  t.string :url, null: false
  t.string :status, default: "active"  # active, disabled, error
  t.datetime :last_connected_at
  t.datetime :last_error_at
  t.text :last_error_message
  t.timestamps
end

add_index :relay_connections, :url, unique: true
```

### Event Publishing

**On profile update** (`after_update_commit` in `User` model):
```ruby
after_update_commit :publish_nostr_profile, if: :profile_changed?

def publish_nostr_profile
  NostrPublishJob.perform_later(self.id, :profile)
end
```

**`NostrPublishJob`** builds and signs events:

- **Kind 0 (Profile):**
  ```json
  {
    "kind": 0,
    "content": "{\"name\":\"Tac\",\"display_name\":\"Tac\",\"about\":\"Bio here\",\"picture\":\"https://inferno.chat/avatars/abc.jpg\",\"nip05\":\"tac@inferno.chat\"}",
    "tags": [],
    "created_at": 1700000000
  }
  ```

- **Kind 3 (Contacts):**
  ```json
  {
    "kind": 3,
    "content": "",
    "tags": [
      ["p", "<friend_pubkey_1>", "wss://relay.friend1.chat", "friend1"],
      ["p", "<friend_pubkey_2>", "wss://relay.friend2.chat", "friend2"]
    ],
    "created_at": 1700000000
  }
  ```

- **Kind 10002 (Relay List):**
  ```json
  {
    "kind": 10002,
    "content": "",
    "tags": [
      ["r", "wss://relay.inferno.chat", "read"],
      ["r", "wss://relay.inferno.chat", "write"]
    ],
    "created_at": 1700000000
  }
  ```

### Profile Pulling

**On remote user join or on-demand:**
```ruby
class NostrProfileFetchJob < ApplicationJob
  def perform(nostr_public_key)
    # Connect to known relays
    # Subscribe to Kind 0 events for this pubkey
    # Update RemoteUser record with latest profile data
  end
end
```

**Periodic refresh:**
```ruby
# lib/tasks/nostr.rake
namespace :nostr do
  desc "Refresh remote user profiles from relays"
  task refresh_profiles: :environment do
    RemoteUser.where("updated_at < ?", 1.hour.ago).find_each do |remote_user|
      NostrProfileFetchJob.perform_later(remote_user.nostr_public_key)
    end
  end
end
```

### Gems & Libraries

| Gem/Library | Purpose |
|-------------|---------|
| `nostr_ruby` | Event creation and signing (already added) |
| `faye-websocket` or `async-websocket` | WebSocket client for connecting to relays |

Add to `Gemfile`:
```ruby
gem "faye-websocket"
```

### Controllers & Endpoints

No new user-facing endpoints. Profile sync is background-only (jobs + rake tasks).

Optional admin endpoint:
```ruby
namespace :admin do
  resources :relays, only: [:index, :create, :destroy] do
    member do
      post :test_connection
    end
  end
end
```

### Verification

- [ ] Updating display name locally publishes a Kind 0 event to connected relays.
- [ ] Adding/removing a friend publishes a Kind 3 event.
- [ ] `NostrProfileFetchJob` retrieves and stores a remote user's latest profile.
- [ ] Remote user's display name and avatar update when their Kind 0 event changes.
- [ ] Relay connection failures are logged and retried gracefully.
- [ ] `rake nostr:refresh_profiles` processes stale remote profiles.

---

## Phase 5: Shared Channels (NIP-29 Relay Groups)

**Goal:** Servers on different instances can share channels, with messages bridged between the local Rails DB and Nostr relay events.

### Concept

A **shared channel** is a local `Channel` that is bridged to a NIP-29 relay-based group. Messages sent locally are also published to the relay group. Messages from remote participants arrive via the relay and are inserted into the local channel.

### Models & Migrations

**Migration: `AddSharedChannelFields`**
```ruby
add_column :channels, :shared, :boolean, default: false
add_column :channels, :nostr_group_id, :string  # NIP-29 group ID
add_column :channels, :nostr_relay_url, :string  # relay hosting the group
add_index :channels, :nostr_group_id
```

**Migration: `CreateNostrEventLog`**
```ruby
create_table :nostr_event_logs do |t|
  t.string :event_id, null: false       # Nostr event ID (sha256 hash)
  t.integer :kind, null: false
  t.string :pubkey, null: false
  t.references :message, foreign_key: true  # linked local message, if any
  t.references :channel, foreign_key: true
  t.string :direction, null: false       # "inbound" or "outbound"
  t.datetime :event_created_at
  t.timestamps
end

add_index :nostr_event_logs, :event_id, unique: true
```

### Message Bridging

**Outbound (local → relay):**
```ruby
# After a message is created in a shared channel
after_create_commit :publish_to_nostr_group, if: -> { channel&.shared? }

def publish_to_nostr_group
  NostrGroupPublishJob.perform_later(self.id)
end
```

The job creates a NIP-29 Kind 9 (group chat message) event:
```json
{
  "kind": 9,
  "content": "Hello from inferno.chat!",
  "tags": [
    ["h", "<group_id>"]
  ]
}
```

**Inbound (relay → local):**

A background process (`NostrGroupSubscriptionJob`) maintains WebSocket subscriptions to relay groups for all shared channels. When a new event arrives:

1. Check if the event is already logged (deduplicate by `event_id`).
2. Verify the signature.
3. Look up or create a `RemoteUser` for the pubkey.
4. Create a local `Message` record in the shared channel.
5. Broadcast via ActionCable (`ChannelChatChannel`) so local users see it in real time.

### NIP-29 Group Management

| NIP-29 Event Kind | Purpose |
|--------------------|---------|
| Kind 9 | Group chat message |
| Kind 10 | Group chat message (threaded reply) |
| Kind 11 | Group thread root |
| Kind 12 | Group note (long-form) |
| Kind 9000–9020 | Group admin events (add/remove user, edit metadata, delete event) |
| Kind 39000–39003 | Group metadata, admins, members |

The server owner or admin who creates a shared channel becomes the NIP-29 group admin on the relay.

### Moderation

- Local admins can delete messages from the shared channel (removes locally + publishes Kind 9005 delete event to the group).
- Local admins can remove remote users from the shared channel (publishes Kind 9001 remove-user event).
- Banning a remote user locally also publishes a remove-user event to the group.

### Controllers & Endpoints

**Channel settings (existing UI):**
- Add "Enable sharing" toggle to channel settings.
- When enabled, the channel creates or joins a NIP-29 group on the instance's relay.
- Display the group's relay URL so admins on other instances can bridge to it.

**Join a shared channel (remote admin):**
```ruby
# POST /servers/:server_id/channels/:id/bridge
# Admin provides a relay URL + group ID to bridge a local channel to a remote NIP-29 group
```

Routes:
```ruby
resources :channels do
  member do
    post :bridge      # Connect to a NIP-29 group
    delete :unbridge  # Disconnect from a NIP-29 group
  end
end
```

### Gems & Libraries

| Gem/Library | Purpose |
|-------------|---------|
| `faye-websocket` | WebSocket subscriptions to relay groups (already added in Phase 4) |

### Verification

- [ ] Admin can enable sharing on a channel; a NIP-29 group is created on the relay.
- [ ] Messages sent locally appear on the relay as Kind 9 events.
- [ ] Messages from remote relay participants appear in the local channel.
- [ ] ActionCable broadcasts remote messages in real time to connected local users.
- [ ] Duplicate events are not inserted (deduplication by `event_id`).
- [ ] Deleting a message locally publishes a Kind 9005 event.
- [ ] Removing a remote user publishes a Kind 9001 event.
- [ ] Bridging a channel to an external group ID works.
- [ ] Unbridging stops the subscription and marks the channel as no longer shared.

---

## Phase 6: Hardening & Advanced Features

**Goal:** Production-readiness for federation — rate limiting, access control, encrypted backups, and abuse prevention.

### Rate Limiting

**Remote auth rate limits:**
```ruby
# config/initializers/rack_attack.rb
Rack::Attack.throttle("nostr_auth/ip", limit: 10, period: 1.minute) do |req|
  req.ip if req.path.start_with?("/auth/nostr")
end

Rack::Attack.throttle("nostr_auth/domain", limit: 30, period: 5.minutes) do |req|
  req.params["home_instance"] if req.path == "/auth/nostr/callback"
end
```

**Relay event rate limits:**
- Max events per pubkey per minute (configurable).
- Max event size (prevent oversized Kind 0 profiles).

### Relay Access Control (NIP-42)

If the instance runs its own strfry relay, configure it to require NIP-42 authentication:

- Only local users and explicitly allowed remote pubkeys can publish.
- Read access can be open or restricted.
- strfry supports `AUTH` event verification natively.

Configuration via strfry policy plugins:
```
# strfry.conf
relay {
  info {
    name = "Inferno Chat Relay"
    description = "Private relay for inferno.chat"
  }
  authentication {
    required = true
    allowed_pubkeys_file = "/etc/strfry/allowed_pubkeys.txt"
  }
}
```

The Rails app syncs the allowed pubkeys file when users sign up or remote users are authorized.

### Invite Lockdown Mode

Extend the existing lockdown toggle (Phase 2) with granular controls:

| Setting | Description |
|---------|-------------|
| `lockdown_remote_auth` | Block all new remote auth attempts |
| `lockdown_remote_joins` | Block remote users from joining new servers |
| `lockdown_local_signups` | Block new local account creation |
| `lockdown_invite_creation` | Block new invite code generation |

Admin UI shows these as toggle switches with an "Emergency Lockdown" button that enables all at once.

### Encrypted Key Backup (NIP-49)

Allow users to export their private key encrypted with a password (NIP-49 `ncryptsec` format):

```ruby
# User clicks "Export Encrypted Key"
# Prompted for a backup password (not their account password)
# Receives an ncryptsec string they can store safely
# To recover: enter ncryptsec + backup password on any instance
```

This is safer than raw `nsec` export and gives users a recovery path independent of any instance.

### Key Rotation

If a user's key is compromised:

1. Instance generates a new keypair.
2. Old public key is added to a Kind 0 event with a `"deprecated": true` tag (or a custom replacement tag).
3. New Kind 0 is published with the new key.
4. Remote instances that cached the old pubkey will see the update on next profile refresh.
5. Active remote sessions for the old pubkey are invalidated.

### Abuse Reporting (NIP-56)

Users can report remote users or content:

- Reports create a local moderation record.
- Optionally publish a NIP-56 Kind 1984 reporting event to relays.
- Admin dashboard shows inbound reports for review.

### Models & Migrations

**Migration: `CreateModerationReports`**
```ruby
create_table :moderation_reports do |t|
  t.references :reporter, null: false, foreign_key: { to_table: :users }
  t.string :reported_pubkey, null: false
  t.string :reported_event_id
  t.string :report_type, null: false  # "spam", "illegal", "impersonation", etc.
  t.text :reason
  t.string :status, default: "open"   # open, reviewed, dismissed, actioned
  t.references :reviewed_by, foreign_key: { to_table: :users }
  t.timestamps
end
```

### Gems & Libraries

| Gem/Library | Purpose |
|-------------|---------|
| `rack-attack` | Rate limiting (likely already in Gemfile) |

### Verification

- [ ] Remote auth is rate-limited: >10 requests/min from one IP are throttled.
- [ ] Remote auth from a specific domain is throttled at >30/5min.
- [ ] Lockdown mode blocks new remote auth when enabled.
- [ ] Granular lockdown toggles work independently.
- [ ] NIP-49 encrypted key export produces a valid `ncryptsec` string.
- [ ] `ncryptsec` import correctly decrypts and restores the keypair.
- [ ] NIP-42 relay auth blocks unauthorized publishers.
- [ ] Moderation reports are created and visible in admin dashboard.
- [ ] NIP-56 reporting events are published to relays when configured.

---

## Dependency Graph

```
Phase 1: Foundation
    ↓
Phase 2: Instance Discovery
    ↓
Phase 3: Cross-Instance Auth  ← requires Phase 1 (keys) + Phase 2 (trust)
    ↓
Phase 4: Profile Sync         ← requires Phase 1 (keys) + Phase 3 (remote users)
    ↓
Phase 5: Shared Channels      ← requires Phase 3 (remote users) + Phase 4 (profiles)
    ↓
Phase 6: Hardening             ← can be applied incrementally alongside Phases 3–5
```

## Library Summary

| Gem/Library | Phase Added | Purpose |
|-------------|-------------|---------|
| `nostr_ruby` | 1 | Key generation, event creation/signing, signature verification |
| `faye-websocket` | 4 | WebSocket client for relay connections |
| `rack-attack` | 6 | HTTP rate limiting |
| **JavaScript** | | |
| `@nostr-dev-kit/ndk` | 1 (frontend) | NIP-07 browser extension integration |
