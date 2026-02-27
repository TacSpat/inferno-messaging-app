# Trust, Compliance & Monetization — Design Document

This document covers designs for safety, compliance, and monetization systems. Each section includes database schema, models, services, and implementation details.

---

## Table of Contents

1. [Audit Logging & Legal Compliance](#1-audit-logging--legal-compliance)
2. [Content Safety: CSAM Detection & Upload Scanning](#2-content-safety-csam-detection--upload-scanning)
3. [User Suspensions](#3-user-suspensions)
4. [Message Integrity & E2EE](#4-message-integrity--e2ee)
5. [Rate Limiting](#5-rate-limiting)
6. [Monetization (Stripe + Zaps)](#6-monetization-stripe--zaps)
7. [Verified User Benefits](#7-verified-user-benefits)
8. [App Updates](#8-app-updates)
9. [Phased Implementation Order](#9-phased-implementation-order)

---

## 1. Audit Logging & Legal Compliance

### Purpose

Provide an immutable record of user activity and moderation actions for legal compliance, evidence preservation, and administration.

### Database Schema

#### `audit_logs`

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `event_type` | `string` | `auth_attempt`, `auth_success`, `auth_failure`, `user_suspended`, `user_unsuspended`, `csam_match_detected`, `ncmec_report_submitted`, `data_export_created`, `settings_changed`, `tier1_verified` |
| `actor_type` | `string` | Polymorphic: `User`, `System` |
| `actor_id` | `bigint` | Polymorphic ID (nullable for system events) |
| `target_type` | `string` | Polymorphic: `User`, `Server`, `Channel`, `Message` |
| `target_id` | `bigint` | Polymorphic ID (nullable) |
| `ip_address` | `string` | Request IP (stored for auth events) |
| `metadata` | `json` | Freeform context |
| `created_at` | `datetime` | Immutable timestamp |

**Indexes:**
- `(event_type, created_at)` — filter by type with time range
- `(actor_type, actor_id)` — look up all events for a user
- `(target_type, target_id)` — look up all events targeting a record

#### `legal_holds`

Prevents data pruning for specific users or servers under legal hold.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `holdable_type` | `string` | Polymorphic: `User`, `Server`, `Channel` |
| `holdable_id` | `bigint` | Polymorphic ID |
| `reason` | `text` | Legal reference / case number |
| `placed_by_id` | `bigint` | FK → `users` (admin) |
| `active` | `boolean` | Default `true` |
| `placed_at` | `datetime` | When the hold was placed |
| `lifted_at` | `datetime` | When lifted (null if active) |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

#### `data_exports`

Tracks data subject access requests (GDPR).

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `user_id` | `bigint` | FK → `users` |
| `requested_by_id` | `bigint` | FK → `users` (admin or self) |
| `export_type` | `string` | `full`, `messages`, `profile`, `audit_log` |
| `status` | `string` | `pending`, `processing`, `completed`, `failed`, `expired` |
| `file_path` | `string` | Path to generated archive |
| `expires_at` | `datetime` | Auto-delete after download window |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

### Services

| Service | Purpose |
|---------|---------|
| `AuditService` | Central logging: `AuditService.log(event_type:, actor:, target:, ip_address:, metadata:)` |
| `DataExportService` | Generates ZIP archive of user data (messages, profile, attachments, audit log). Runs as a Solid Queue job. |

### Controllers

| Controller | Routes | Purpose |
|------------|--------|---------|
| `Admin::AuditLogsController` | `GET /admin/audit_logs` | Paginated, filterable log viewer |
| `Admin::LegalHoldsController` | CRUD `/admin/legal_holds` | Manage legal holds |
| `Admin::DataExportsController` | CRUD `/admin/data_exports` | Initiate and download exports |

---

## 2. Content Safety: CSAM Detection & Upload Scanning

### Purpose

Detect, quarantine, and report child sexual abuse material (CSAM) per federal law (18 U.S.C. 2258A). Provide upload scanning, hash matching, and NCMEC CyberTipline reporting.

### Database Schema

#### `content_hashes`

Perceptual hash (pHash) and SHA-256 of every uploaded image blob.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `blob_id` | `bigint` | FK → `active_storage_blobs` |
| `sha256` | `string(64)` | SHA-256 hex digest |
| `phash` | `string(16)` | 64-bit perceptual hash (dHash via `dhash-vips`) |
| `match_status` | `string` | `clean`, `matched`, `pending_review` |
| `matched_known_bad_hash_id` | `bigint` | FK → `known_bad_hashes` (nullable) |
| `scanned_at` | `datetime` | When the scan completed |
| `created_at` | `datetime` | |

#### `known_bad_hashes`

Known-bad hashes seeded from NCMEC, Project VIC, or local confirmed matches.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `hash_type` | `string` | `sha256`, `phash` |
| `hash_value` | `string` | The hash value |
| `source` | `string` | `ncmec`, `project_vic`, `local_confirmed` |
| `severity` | `string` | `confirmed_csam`, `suspected`, `non_photographic` |
| `active` | `boolean` | Default `true` |
| `created_at` | `datetime` | |

#### `quarantined_uploads`

Uploads that matched a known-bad hash. Content is preserved under legal hold but hidden from users.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `content_hash_id` | `bigint` | FK → `content_hashes` |
| `blob_id` | `bigint` | FK → `active_storage_blobs` |
| `uploader_id` | `bigint` | FK → `users` |
| `uploader_ip` | `string` | IP address at time of upload |
| `matched_hash_id` | `bigint` | FK → `known_bad_hashes` |
| `match_type` | `string` | `exact_sha256`, `perceptual_phash` |
| `match_distance` | `integer` | Hamming distance for pHash matches |
| `status` | `string` | `quarantined`, `confirmed_csam`, `false_positive`, `reported_to_ncmec` |
| `auto_suspended` | `boolean` | Whether this triggered an automatic user suspension |
| `reviewed_by_id` | `bigint` | FK → `users` (admin who reviewed) |
| `reviewed_at` | `datetime` | |
| `created_at` | `datetime` | |

#### `ncmec_reports`

CyberTipline submissions to NCMEC.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `report_id` | `string` | NCMEC-assigned report ID |
| `status` | `string` | `draft`, `submitted`, `accepted`, `rejected` |
| `suspect_user_id` | `bigint` | FK → `users` |
| `suspect_ip` | `string` | IP address at time of incident |
| `incident_datetime` | `datetime` | When the content was uploaded |
| `incident_summary` | `text` | Description of the incident |
| `submitted_at` | `datetime` | |
| `created_at` | `datetime` | |

### Scanning Pipeline

```
User uploads image
        │
        ▼
Controller saves message normally
        │
        └── after_action: ScannableUpload detects new image blob(s)
                │
                ├── upload_scanning_enabled? → no → done
                │
                └── yes → UploadScanJob.perform_later(blob_id)
                        │
                        ▼
                UploadScanService.call(blob)
                        │
                        ├── Compute SHA-256 digest
                        ├── Compute pHash via dhash-vips
                        ├── Create ContentHash record
                        │
                        ├── KnownBadHash.match?(sha256:, phash:, threshold:)
                        │     │
                        │     ├── No match → clean → done
                        │     │
                        │     └── Match found!
                        │           │
                        │           ▼
                        │     QuarantineService.call
                        │           ├── Hide content
                        │           ├── Create QuarantinedUpload record
                        │           ├── Create ModerationReport (type: csam, priority: 2)
                        │           ├── Create LegalHold (90-day minimum)
                        │           ├── Auto-suspend user (if configured)
                        │           └── AuditService.log
```

### Admin Review: One-Click CSAM Action Panel

When admin confirms a CSAM match, a single click does:
- Confirm as CSAM
- Suspend user (permanent)
- Place legal hold (90 days)
- Create NCMEC report draft
- Publish NIP-56 report event to relays
- Close all other reports for this user

### Services

| Service | Purpose |
|---------|---------|
| `UploadScanService` | Compute SHA-256 + pHash, check against known-bad database |
| `QuarantineService` | Hide content, create records, auto-suspend, audit log |
| `NcmecReportService` | Build and submit CyberTipline reports |
| `ContentHashImportService` | Bulk import known-bad hashes |
| `CsamEscalationService` | Escalate unresolved CSAM reports after configurable hours |

### New Gem

| Gem | Purpose |
|-----|---------|
| `dhash-vips` | Perceptual hashing via `ruby-vips` — reuses existing `image_processing` bindings |

---

## 3. User Suspensions

### Purpose

Instance-wide user suspensions (temporary or permanent) with Devise integration.

### Database Schema

#### `user_suspensions`

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `user_id` | `bigint` | FK → `users` |
| `suspension_type` | `string` | `temporary`, `permanent` |
| `reason` | `text` | Human-readable reason |
| `reason_category` | `string` | `csam`, `spam`, `harassment`, `illegal`, `admin_action` |
| `auto_triggered` | `boolean` | Whether triggered automatically by scanning pipeline |
| `suspended_by_id` | `bigint` | FK → `users` (admin, nullable for auto) |
| `expires_at` | `datetime` | Null for permanent suspensions |
| `lifted_at` | `datetime` | When lifted (null if active) |
| `lifted_by_id` | `bigint` | FK → `users` |
| `lift_reason` | `text` | Why the suspension was lifted |
| `created_at` | `datetime` | |

### Suspension Flow

```
Admin clicks "Suspend User" (or auto-triggered by CSAM match)
        │
        ▼
UserSuspensionService.suspend!(user, params)
        │
        ├── Create UserSuspension record
        ├── Set user.suspended_at = Time.current (denormalized for O(1) Devise auth check)
        ├── Invalidate all active sessions (immediate logout)
        ├── Hide user content via query scope (NOT deleted — preserved for evidence)
        └── AuditService.log
```

### Suspendable Concern

Mixed into `User`. Overrides Devise `active_for_authentication?` to return `false` when `suspended_at` is present.

### Jobs

| Job | Purpose |
|-----|---------|
| `LiftExpiredSuspensionsJob` | Recurring hourly — finds expired suspensions and lifts them |

---

## 4. Message Integrity & E2EE

### 4a. Message Signatures

Every message carries a cryptographic signature proving the author wrote that exact content.

**Database changes — `messages` table:**

| Column | Type | Description |
|--------|------|-------------|
| `nostr_event_id` | `string` | Nostr event ID (SHA-256 of serialized event) |
| `signature` | `string` | Schnorr signature (hex-encoded) |

**Service:** `MessageSigningService` — sign on create, verify on display.

All messages are signed, not just relay-bound ones. This provides a universal integrity guarantee.

### 4b. NIP-44 Encrypted DMs

DM content encrypted client-side so only conversation participants can read it.

**Database changes — `messages` table:**

| Column | Type | Description |
|--------|------|-------------|
| `encrypted_content` | `text` | NIP-44 ciphertext (DM conversations only) |
| `encrypted_content_nonce` | `string` | Per-message nonce |

**Encryption scheme:** NIP-44 (XChaCha20-Poly1305 with HKDF-derived shared secret from sender + recipient Nostr keys)

Encryption happens in the **Stimulus controller (client-side JS)** using `nostr-tools`. The server never sees plaintext for E2EE DMs.

**E2EE vs. Content Safety trade-off:** E2EE DMs cannot be scanned server-side. This is inherent to E2EE and shared by Signal, WhatsApp, etc. Compliance obligations apply to content the provider has knowledge of; E2EE messages are opaque to the server.

**Rollout:** Gradual — unencrypted DMs remain functional during transition. Encryption is opt-in per conversation until all clients support it.

---

## 5. Rate Limiting

### Purpose

Rate limit API endpoints to prevent abuse. Uses `Rack::Attack`.

### Configuration

Rate limits stored in server settings as JSON, configurable by admin:

```json
{
  "login_per_20s": 5,
  "registration_per_hour": 3,
  "api_per_minute": 120,
  "api_per_hour": 5000
}
```

### Implementation

```ruby
# config/initializers/rack_attack.rb
Rack::Attack.throttle("login/ip", limit: 5, period: 20.seconds) do |req|
  req.ip if req.path == "/users/sign_in" && req.post?
end

Rack::Attack.throttle("registration/ip", limit: 3, period: 1.hour) do |req|
  req.ip if req.path == "/users" && req.post?
end

Rack::Attack.throttle("api/user", limit: 120, period: 1.minute) do |req|
  req.env["warden"]&.user&.id
end
```

Rate limit headers (`X-RateLimit-Limit`, `X-RateLimit-Remaining`, `X-RateLimit-Reset`, `Retry-After`) on all throttled responses.

---

## 6. Monetization (Stripe + Zaps)

### Purpose

Two payment paths: **Stripe** (credit/debit card) for mainstream users, and **Zaps** (Bitcoin Lightning via NIP-57) for crypto-native users.

### Database Schema

#### `payment_records`

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `user_id` | `bigint` | FK → `users` |
| `payment_type` | `string` | `stripe`, `zap` |
| `payment_purpose` | `string` | `verification`, `cosmetic`, `boost`, `tip` |
| `amount_sats` | `bigint` | Amount in satoshis (canonical unit) |
| `amount_fiat` | `decimal(10,2)` | Fiat amount (for Stripe) |
| `fiat_currency` | `string` | `USD`, `EUR`, etc. |
| `status` | `string` | `pending`, `completed`, `failed`, `refunded`, `expired` |
| `stripe_payment_intent_id` | `string` | Stripe PaymentIntent ID (nullable) |
| `lightning_invoice` | `text` | BOLT11 invoice string (nullable) |
| `lightning_payment_hash` | `string` | Lightning payment hash (nullable) |
| `nostr_zap_receipt_id` | `string` | NIP-57 zap receipt event ID (nullable) |
| `completed_at` | `datetime` | |
| `created_at` | `datetime` | |

#### `payment_config`

Singleton — one row defines all payment settings.

| Column | Type | Description |
|--------|------|-------------|
| `stripe_enabled` | `boolean` | Whether Stripe is active |
| `stripe_publishable_key` | `string` | Stripe public key |
| `stripe_secret_key_encrypted` | `text` | Encrypted Stripe secret key |
| `zaps_enabled` | `boolean` | Whether Lightning Zaps are active |
| `lightning_address` | `string` | Lightning address for receiving payments |
| `verification_price_sats` | `bigint` | Verification price in sats |
| `verification_price_fiat` | `decimal(10,2)` | Verification price in fiat |

### What Users Can Buy

**Cosmetics** — animated avatars, profile effects, custom colors, badges, premium sticker packs. Stored as tags on the user's Nostr profile (Kind 0), so they travel across any Nostr client automatically.

**Verification badge** — small one-time payment for a verified badge. Not required for anything, but signals legitimacy.

**Server boosts** — social support. Boosted servers get a badge, boosters get a visible role.

**Tipping** — direct user-to-user via Zaps or Stripe.

### Services

| Service | Purpose |
|---------|---------|
| `StripePaymentService` | Create PaymentIntent, handle webhooks, confirm payment |
| `ZapPaymentService` | Generate Lightning invoice, verify NIP-57 zap receipt |
| `VerificationPaymentService` | Orchestrate: determine payment methods, delegate, handle verification promotion |

### Flow: Stripe Verification

```
User clicks "Get Verified"
        │
        ▼
POST /payments/stripe/create_intent
        │
        ▼
StripePaymentService creates PaymentIntent + PaymentRecord (pending)
        │
        ▼
Frontend: Stripe.js collects card → confirmCardPayment
        │
        ▼
Stripe webhook → payment_intent.succeeded
        │
        ├── PaymentRecord.complete!
        ├── User gets verified badge
        └── AuditService.log
```

### Flow: Lightning Zap Verification

```
User clicks "Pay with Lightning"
        │
        ▼
POST /payments/zaps/create_invoice
        │
        ▼
ZapPaymentService generates BOLT11 invoice via LNURL
        │
        ▼
Frontend displays QR code / "Open in wallet"
        │
        ▼
User pays in Lightning wallet
        │
        ▼
Zap receipt (Kind 9735) appears on relay OR webhook
        │
        ├── PaymentRecord.complete!
        ├── User gets verified badge
        └── AuditService.log
```

### New Gem

| Gem | Purpose |
|-----|---------|
| `stripe` | Stripe API client |

---

## 7. Verified User Benefits

### Purpose

Configurable perks for verified users (those who completed a verification payment).

### Database Schema

#### `verified_user_benefits`

Singleton config — one row defines all benefit settings.

| Column | Type | Description |
|--------|------|-------------|
| `max_servers_per_user` | `integer` | Override limit for verified users (0 = use default) |
| `max_upload_size_mb` | `integer` | Override upload limit |
| `max_emojis_per_server` | `integer` | Override emoji limit for verified server owners |
| `animated_avatar_enabled` | `boolean` | Can use animated GIF avatars |
| `custom_profile_badges` | `boolean` | Gets a "Verified" badge (default `true`) |
| `higher_rate_limits` | `boolean` | Uses elevated rate limits (default `true`) |
| `screen_share_hd` | `boolean` | HD screen sharing in voice |

#### `custom_themes`

User-created color themes (gated behind verification if configured).

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `user_id` | `bigint` | FK → `users` |
| `name` | `string(50)` | Theme name |
| `theme_data` | `json` | Color palette, CSS variable overrides |
| `public` | `boolean` | Whether others can use this theme |
| `created_at` | `datetime` | |

### Service

| Service | Purpose |
|---------|---------|
| `UserBenefitsService` | Central query: `limit_for(user, :max_servers_per_user)` returns verified override or default. `can?(user, :custom_themes)` returns boolean. |

### Gated Servers & Channels

Server owners can optionally require verification to join (`server.requires_verification`). Channel admins can require verification to access specific channels (`channel.requires_verification`).

---

## 8. App Updates

### Purpose

Check for new releases via GitHub Releases API and notify admins.

### Database Schema

#### `app_update_notifications`

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `version` | `string` | Release version tag |
| `release_name` | `string` | GitHub release title |
| `release_notes` | `text` | Release body (Markdown) |
| `release_url` | `string` | URL to GitHub release page |
| `published_at` | `datetime` | |
| `dismissed_by_id` | `bigint` | FK → `users` (admin who dismissed) |
| `dismissed_at` | `datetime` | |
| `created_at` | `datetime` | |

### Service

`AppUpdateCheckService` — calls GitHub Releases API, compares versions via `Gem::Version`, creates `AppUpdateNotification` for newer releases.

### Job

`CheckAppUpdatesJob` — runs daily via Solid Queue. Calls `AppUpdateCheckService`.

### Admin UI

Dashboard banner: "Inferno v1.2.0 is available (you're running v1.1.0)" with link to release notes and dismiss button.

---

## 9. Phased Implementation Order

### Phase A: Audit Logging (Foundation)

**Dependencies:** None

**Deliverables:**
- `AuditLog` model + migration
- `AuditService`
- Admin audit log viewer
- `LegalHold`, `DataExport` models

**Why first:** Every subsequent system generates audit events.

---

### Phase B: User Suspensions + Content Safety

**Dependencies:** Phase A

**Sub-phases:**

1. **B.1: User Suspensions** — `UserSuspension` model, `Suspendable` concern, `UserSuspensionService`, `LiftExpiredSuspensionsJob`, admin UI
2. **B.2: Hash Tables + Scan Pipeline** — `ContentHash`, `KnownBadHash`, `UploadScanService`, `ScannableUpload` concern, `dhash-vips` gem
3. **B.3: Quarantine + Escalation** — `QuarantinedUpload`, `QuarantineService`, `CsamEscalationService`, admin review queue, one-click CSAM action panel
4. **B.4: NCMEC Reporting** — `NcmecReport`, `NcmecReportService`, admin reporting UI

---

### Phase C: Message Integrity

**Dependencies:** Phase A

1. **C.1: Message Signatures** — `nostr_event_id` + `signature` columns on messages, `MessageSigningService`
2. **C.2: E2EE DMs** — `encrypted_content` columns, client-side NIP-44 encryption

---

### Phase D: Monetization + Verification

**Dependencies:** Phase A

**Deliverables:**
- `PaymentRecord`, `PaymentConfig` models
- `StripePaymentService`, `ZapPaymentService`, `VerificationPaymentService`
- Payment controllers + admin config
- `VerifiedUserBenefit` config, `UserBenefitsService`
- `CustomTheme` model
- `stripe` gem

---

### Phase E: App Updates

**Dependencies:** None (standalone)

**Deliverables:**
- `AppUpdateNotification` model
- `AppUpdateCheckService`
- `CheckAppUpdatesJob` (daily via Solid Queue)
- Admin dashboard banner

---

### Dependency Graph

```
Phase A: Audit Logging
    │
    ├── Phase B: Content Safety (B.1 → B.2 → B.3 → B.4)
    │
    ├── Phase C: Message Integrity (C.1 → C.2)
    │
    └── Phase D: Monetization + Verification

Phase E: App Updates (independent)
```

### New Gems

| Gem | Phase | Purpose |
|-----|-------|---------|
| `dhash-vips` | B.2 | Perceptual hashing via `ruby-vips` |
| `stripe` | D | Stripe API client |
