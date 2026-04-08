# Trust, Compliance & Monetization -- Design Document (Flutter)

This document covers designs for safety, compliance, and monetization systems in the Flutter client. All processing is on-device. There is no server component -- the app communicates with Nostr relays and external APIs directly. Database schemas are Drift table definitions (SQLite).

---

## Table of Contents

1. [Audit Logging & Legal Compliance](#1-audit-logging--legal-compliance)
2. [Content Safety: CSAM Detection & Upload Scanning](#2-content-safety-csam-detection--upload-scanning)
3. [User Blocking & Muting](#3-user-blocking--muting)
4. [Message Integrity & E2EE](#4-message-integrity--e2ee)
5. [Rate Limiting](#5-rate-limiting)
6. [Monetization (Stripe + Zaps)](#6-monetization-stripe--zaps)
7. [Verified User Benefits](#7-verified-user-benefits)
8. [App Updates](#8-app-updates)
9. [Phased Implementation Order](#9-phased-implementation-order)

---

## 1. Audit Logging & Legal Compliance

### Purpose

Provide a local, immutable record of safety-relevant events for the user's own records, evidence preservation, and authority reporting. Since there is no server, all audit data lives in the local SQLite database.

### Drift Table Definitions

#### `AuditLogs`

```dart
class AuditLogs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get eventType => text()(); // 'csam_match_detected', 'content_hidden', 'content_unhidden', 'authority_report_generated', 'data_export_created', 'settings_changed'
  TextColumn get actorPubkey => text().nullable()(); // Nostr pubkey of acting user (null for system events)
  TextColumn get targetType => text().nullable()(); // 'message', 'user', 'server', 'channel'
  IntColumn get targetId => integer().nullable()();
  TextColumn get targetPubkey => text().nullable()(); // Nostr pubkey of target (for user-level events)
  TextColumn get metadata => text().withDefault(const Constant('{}'))(); // JSON freeform context
  DateTimeColumn get createdAt => dateTime()();
}
```

**Indexes:**
- `(eventType, createdAt)` -- filter by type with time range
- `(actorPubkey)` -- look up all events for a pubkey
- `(targetType, targetId)` -- look up all events targeting a record

#### `DataExports`

Tracks user-initiated data exports (personal data download).

```dart
class DataExports extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get exportType => text()(); // 'full', 'messages', 'profile', 'audit_log'
  TextColumn get status => text()(); // 'pending', 'processing', 'completed', 'failed'
  TextColumn get filePath => text().nullable()(); // Path to generated archive on disk
  DateTimeColumn get expiresAt => dateTime().nullable()(); // Auto-delete after window
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
```

### Services

| Service | Purpose |
|---------|---------|
| `AuditService` | Central logging: `AuditService.log(eventType:, actorPubkey:, targetType:, targetId:, metadata:)` writes to local `audit_logs` table |
| `DataExportService` | Generates ZIP archive of user data (messages, profile, attachments, audit log). Runs in a Dart isolate to avoid blocking the UI thread. |

### UI

| Screen | Purpose |
|--------|---------|
| Safety Settings > Audit Log | Paginated, filterable log viewer within the app |
| Safety Settings > Data Export | Initiate and download personal data exports |

---

## 2. Content Safety: CSAM Detection & Upload Scanning

### Purpose

Detect, quarantine, and enable reporting of child sexual abuse material (CSAM). All scanning is performed on-device using perceptual hashing and ONNX-based classifiers. No images leave the device for scanning purposes.

### Drift Table Definitions

#### `ContentHashes`

Perceptual hash (dHash) of every scanned image attachment, stored locally.

```dart
class ContentHashes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get hashType => text().withDefault(const Constant('dhash'))();
  TextColumn get hashValue => text()();
  TextColumn get mediaType => text().nullable()();
  RealColumn get confidence => real().withDefault(const Constant(1.0))();
  BoolColumn get allowlisted => boolean().withDefault(const Constant(false))();
  IntColumn get reporterCount => integer().withDefault(const Constant(1))();
  TextColumn get reporterPubkeys => text().withDefault(const Constant('[]'))(); // JSON array
  TextColumn get nostrEventIds => text().withDefault(const Constant('[]'))(); // JSON array
  IntColumn get messageId => integer().nullable()();
  TextColumn get originalFilename => text().nullable()();
  TextColumn get source => text().withDefault(const Constant('local'))(); // 'local', 'shared'
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
```

#### `CsamHashEntries`

Known-bad hashes: seeded from shared hash network (NIP-56 reports) or confirmed locally.

```dart
class CsamHashEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get hashValue => text()();
  TextColumn get hashType => text().withDefault(const Constant('dhash'))();
  TextColumn get listSource => text()(); // 'shared_promotion', 'local_confirmed'
  DateTimeColumn get addedAt => dateTime()();
}
```

#### `HiddenAttachmentRecords`

Records of attachments that were purged from hidden messages, preserving metadata for authority reports.

```dart
class HiddenAttachmentRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get messageId => integer()();
  TextColumn get originalFilename => text()();
  TextColumn get contentType => text().nullable()();
  IntColumn get byteSize => integer().nullable()();
  TextColumn get checksum => text().nullable()();
  DateTimeColumn get purgedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();
}
```

### On-Device Scanning Pipeline

```
Message arrives (DM or channel message with image attachments)
        |
        v
ContentSafetyService.check(messageId)
        |
        +-- Stage 0: CSAM hash match (always on, non-negotiable)
        |     |
        |     +-- ImageHasher.hashMessageAttachments() computes dHash
        |     |   using the `image` Dart package (9x8 grayscale, 64-bit difference hash)
        |     |
        |     +-- Compare against CsamHashEntries table (Hamming distance <= 10)
        |     |
        |     +-- Match found?
        |           |
        |           +-- Yes: auto-hide message, purge file URLs,
        |           |        store HiddenAttachmentRecord, log to AuditService
        |           |        (CSAM hides are NOT reversible by the user)
        |           |
        |           +-- No: continue to stage 1
        |
        +-- Stage 1: NSFW detection (ONNX Runtime via FFI)
        |     |
        |     +-- Pre-filter: Marqo ViT-Tiny (384x384) - high sensitivity
        |     |   Score < 0.5 -> safe, skip confirmation
        |     |
        |     +-- Confirmation: TostAI FocalNet-Base (224x224)
        |     |   5-class: drawings, hentai, neutral, porn, sexy
        |     |
        |     +-- Flagged? auto-hide with reason 'nsfw'
        |
        +-- Stages 2-5: Text/reputation/hash filters
              (see ContentSafetyService for full filter chain)
```

### Shared Hash Network (NIP-56)

The `SharedHashService` periodically fetches Kind 1984 report events from Nostr relays. These events contain `["x", "<hash>", "<type>"]` tags with content hashes reported by other users in the network.

- Reports are aggregated into the local `content_hashes` table with confidence scoring
- Friend reporters are weighted 2x (configurable)
- When a hash reaches the confidence threshold AND minimum reporter count, it is auto-promoted to `csam_hash_entries` for mandatory blocking
- Allowlisted hashes are never promoted

### Authority Reporting

Since there is no server to file NCMEC CyberTipline reports programmatically, the app provides tools for the user to generate structured reports for law enforcement:

- `AuthorityReportGenerator` (`lib/services/authority_report_generator.dart`) produces a plaintext report containing: incident summary, message metadata, sender pubkey, timestamps, content hashes, and hidden attachment records
- The Authority Report screen (`lib/screens/settings/authority_report_screen.dart`) lets the user select a category, generate the report, and copy it to clipboard for submission to the appropriate authority
- NIP-56 report events (Kind 1984) can be published to relays to contribute to the shared hash network

### Services

| Service | Purpose |
|---------|---------|
| `ContentSafetyService` | Orchestrates all content safety checks. Called after message insert. Six-stage filter pipeline (CSAM hash, NSFW, unknown sender, report threshold, reputation, image hash) plus text filters. |
| `ImageHasher` | Computes dHash using the `image` Dart package. Static methods for hashing and Hamming distance comparison. |
| `NsfwDetector` | Two-stage ONNX Runtime pipeline via FFI. Singleton with lazy model loading. |
| `SharedHashService` | Fetches NIP-56 report events from relays, aggregates hash confidence, auto-promotes high-confidence hashes to CSAM entries. |
| `ReputationScorer` | Multi-signal weighted reputation scoring (friend status, report count, account age, etc.) |
| `AuthorityReportGenerator` | Generates structured plaintext reports for law enforcement submission. |

### Dart Packages

| Package | Purpose |
|---------|---------|
| `image` | Pure Dart image decoding/resizing for dHash computation |
| `onnxruntime` (FFI) | ONNX model inference for NSFW detection (`lib/src/onnxruntime_bindings.dart`) |

---

## 3. User Blocking & Muting

### Purpose

Since there is no centralized server to suspend accounts, content moderation is local. Users block or mute other pubkeys, and the app enforces these locally.

### Existing Drift Tables

Blocking and muting are handled through the existing `Contacts` table (`friendship_status` field) and the `ContentSafetyService` filter chain (unknown sender, report threshold, reputation score).

### Blocking Flow

```
User taps "Block" on a profile or message
        |
        v
ContactService.block(pubkey)
        |
        +-- Update contact record: friendshipStatus = blocked
        +-- Publish NIP-56 report event to relays (optional, user-configurable)
        +-- Hide all existing messages from this pubkey
        +-- AuditService.log('user_blocked', ...)
```

### Auto-Hide Escalation

The `ContentSafetyService` automatically hides content from senders who exceed the report threshold or fall below the reputation threshold. These are configurable per-user in Safety Settings:

- **Protection level**: `standard` (all filters active) or `minimal` (CSAM + NSFW only)
- **Report threshold**: number of reports before auto-hide
- **Reputation sensitivity**: weight multiplier for reputation scoring
- **Image hash matching**: toggle perceptual hash comparison
- **Text filters**: block links, phone numbers, ALL CAPS, spam characters, keyword filter

All auto-hides (except CSAM) are reversible via the Safety Settings UI.

---

## 4. Message Integrity & E2EE

### 4a. Message Signatures

Every message carries a Nostr event signature proving the author wrote that exact content.

**Messages table columns (already present):**

| Column | Type | Description |
|--------|------|-------------|
| `nostrEventId` | `text` | Nostr event ID (SHA-256 of serialized event) |
| `nostrSignature` | `text` | Schnorr signature (hex-encoded) |

**Service:** Message signing and verification is handled inline by `GroupMessageService` and `DmService` using the `nostr` Dart utilities. All messages are signed at creation time using the local Nostr keypair.

### 4b. NIP-44 Encrypted DMs

DM content is encrypted client-side so only conversation participants can read it.

**Encryption scheme:** NIP-44 (XChaCha20-Poly1305 with HKDF-derived shared secret from sender + recipient Nostr keys)

Encryption and decryption happen entirely on-device in `DmService`. The plaintext never leaves the local process.

**E2EE vs. Content Safety trade-off:** E2EE DMs cannot be scanned by anyone other than the recipient. The on-device `ContentSafetyService` runs after decryption on the recipient's device, so CSAM hash matching and NSFW detection still work for incoming DMs -- this is a significant advantage over server-side architectures where E2EE messages are completely opaque.

**Identity:** There is no Devise or username/password system. Identity is a Nostr keypair managed by `KeyManagementService`. Authentication is proving possession of the private key via Schnorr signatures.

---

## 5. Rate Limiting

### Purpose

Since there is no server to rate-limit, abuse prevention is handled differently:

1. **Relay-side rate limiting** -- Nostr relays enforce their own rate limits on event publishing. The app respects `NOTICE` and rate-limit responses from relays.

2. **Client-side throttling** -- `ServerPublishService` and `DmService` implement local debouncing and batching to avoid flooding relays:
   - Message publishing: debounced per-channel (prevents accidental double-sends)
   - Typing indicators: throttled to one event per 3 seconds
   - Presence updates: throttled to one event per 30 seconds

3. **Incoming message filtering** -- The `ContentSafetyService` filter chain handles spam from other users (report threshold, reputation scoring, text filters for spam characters and ALL CAPS).

No additional rate-limit infrastructure is needed beyond what the relay protocol and content safety pipeline already provide.

---

## 6. Monetization (Stripe + Zaps)

### Purpose

Two payment paths: **Stripe** (credit/debit card) for mainstream users, and **Zaps** (Bitcoin Lightning via NIP-57) for crypto-native users. All payment flows are initiated client-side.

### Drift Table Definitions

#### `PaymentRecords`

```dart
class PaymentRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get paymentType => text()(); // 'stripe', 'zap'
  TextColumn get paymentPurpose => text()(); // 'verification', 'cosmetic', 'boost', 'tip'
  IntColumn get amountSats => integer()(); // Amount in satoshis (canonical unit)
  RealColumn get amountFiat => real().nullable()(); // Fiat amount (for Stripe)
  TextColumn get fiatCurrency => text().nullable()(); // 'USD', 'EUR', etc.
  TextColumn get status => text()(); // 'pending', 'completed', 'failed', 'refunded', 'expired'
  TextColumn get stripePaymentIntentId => text().nullable()();
  TextColumn get lightningInvoice => text().nullable()(); // BOLT11 invoice string
  TextColumn get lightningPaymentHash => text().nullable()();
  TextColumn get nostrZapReceiptId => text().nullable()(); // NIP-57 zap receipt event ID
  DateTimeColumn get completedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime()();
}
```

#### `PaymentConfig`

Singleton -- one row defines all payment settings.

```dart
class PaymentConfig extends Table {
  IntColumn get id => integer().autoIncrement()();
  BoolColumn get stripeEnabled => boolean().withDefault(const Constant(false))();
  TextColumn get stripePublishableKey => text().nullable()();
  BoolColumn get zapsEnabled => boolean().withDefault(const Constant(false))();
  TextColumn get lightningAddress => text().nullable()(); // For receiving payments
  IntColumn get verificationPriceSats => integer().withDefault(const Constant(0))();
  RealColumn get verificationPriceFiat => real().withDefault(const Constant(0.0))();
}
```

### What Users Can Buy

**Cosmetics** -- animated avatars, profile effects, custom colors, badges, premium sticker packs. Stored as tags on the user's Nostr profile (Kind 0), so they travel across any Nostr client automatically.

**Verification badge** -- small one-time payment for a verified badge. Not required for anything, but signals legitimacy.

**Server boosts** -- social support. Boosted servers get a badge, boosters get a visible role.

**Tipping** -- direct user-to-user via Zaps or Stripe.

### Services

| Service | Purpose |
|---------|---------|
| `StripePaymentService` | Opens Stripe Checkout via URL launcher or in-app WebView. Handles deep-link callback for payment confirmation. |
| `ZapPaymentService` | Generates NIP-57 zap request, fetches BOLT11 invoice via LNURL, monitors relays for zap receipt (Kind 9735). |
| `VerificationPaymentService` | Orchestrates: determine available payment methods, delegate to Stripe or Zap service, update verification status on completion. |

### Flow: Stripe Verification

```
User taps "Get Verified"
        |
        v
StripePaymentService creates PaymentRecord (pending)
        |
        v
Open Stripe Checkout URL (via url_launcher or WebView)
        |
        v
User completes payment in browser/WebView
        |
        v
Stripe redirects back to app via deep link (custom URL scheme)
        |
        +-- StripePaymentService verifies payment via Stripe API
        +-- PaymentRecord updated to 'completed'
        +-- User gets verified badge (Kind 0 profile tag)
        +-- AuditService.log
```

### Flow: Lightning Zap Verification

```
User taps "Pay with Lightning"
        |
        v
ZapPaymentService creates NIP-57 zap request event
        |
        v
Fetch BOLT11 invoice from recipient's LNURL endpoint
        |
        v
Display QR code / "Open in wallet" button
        |
        v
User pays in Lightning wallet
        |
        v
ZapPaymentService monitors relays for zap receipt (Kind 9735)
        |
        +-- PaymentRecord updated to 'completed'
        +-- User gets verified badge
        +-- AuditService.log
```

### Dart Packages

| Package | Purpose |
|---------|---------|
| `url_launcher` | Open Stripe Checkout in external browser |
| `uni_links` / `app_links` | Handle deep-link callbacks from Stripe |

---

## 7. Verified User Benefits

### Purpose

Configurable perks for verified users (those who completed a verification payment).

### Drift Table Definitions

#### `VerifiedUserBenefits`

Singleton config -- one row defines all benefit settings.

```dart
class VerifiedUserBenefits extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get maxServersPerUser => integer().withDefault(const Constant(0))(); // 0 = use default
  IntColumn get maxUploadSizeMb => integer().withDefault(const Constant(0))();
  IntColumn get maxEmojisPerServer => integer().withDefault(const Constant(0))();
  BoolColumn get animatedAvatarEnabled => boolean().withDefault(const Constant(false))();
  BoolColumn get customProfileBadges => boolean().withDefault(const Constant(true))();
  BoolColumn get screenShareHd => boolean().withDefault(const Constant(false))();
}
```

#### `CustomThemes`

User-created color themes (optionally gated behind verification).

```dart
class CustomThemes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(max: 50)();
  TextColumn get themeData => text()(); // JSON color palette
  BoolColumn get isPublic => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
}
```

### Service

| Service | Purpose |
|---------|---------|
| `UserBenefitsService` | Central query: `limitFor(benefitKey)` returns verified override or default. `can(featureKey)` returns boolean. Checks local user's verification status (Kind 0 profile tag). |

### Gated Servers & Channels

Server owners can optionally require verification to join (stored as a tag in the server's Nostr event). Channel admins can require verification to access specific channels (stored in channel metadata).

---

## 8. App Updates

### Purpose

Check for new releases and notify the user. Desktop and mobile use different update mechanisms.

### Desktop: GitHub Releases API

`AppUpdateService` (`lib/services/app_update_service.dart`) handles desktop updates:

- Calls the GitHub Releases API to check for newer versions
- Compares semver strings (current version from `package_info_plus` vs. latest release tag)
- Finds the correct platform-specific asset (`.exe` / `.AppImage` / `.tar.gz` / `.dmg` / `.zip`)
- Downloads with progress tracking, then spawns a platform-specific helper script that:
  - Waits for the app to exit
  - Extracts the archive
  - Replaces the app bundle directory
  - Relaunches the app

### Mobile: App Store Updates

Mobile platforms use their native update mechanisms:
- **Android**: Google Play Store (or GitHub Releases for sideloaded builds)
- **iOS**: Apple App Store

The unified `AppUpdateProvider` wraps both paths and exposes a consistent API to the UI.

### UI

Dashboard banner: "Inferno vX.Y.Z is available (you're running vA.B.C)" with a link to release notes, a download button (desktop), or a "View in Store" button (mobile). Dismiss button hides the banner until the next new release.

---

## 9. Phased Implementation Order

### Phase A: Audit Logging (Foundation)

**Dependencies:** None

**Deliverables:**
- `AuditLogs` Drift table
- `AuditService`
- Audit log viewer in Safety Settings
- `DataExports` Drift table + `DataExportService` (runs in isolate)

**Why first:** Every subsequent system generates audit events.

---

### Phase B: Content Safety

**Dependencies:** Phase A

**Sub-phases:**

1. **B.1: On-Device Hash Pipeline** -- `ContentHashes` Drift table, `CsamHashEntries` Drift table, `ImageHasher` (dHash via `image` package), `ContentSafetyService` filter chain
2. **B.2: NSFW Detection** -- `NsfwDetector` (ONNX Runtime via FFI), two-stage pipeline (Marqo ViT-Tiny + TostAI FocalNet), model download and caching
3. **B.3: Shared Hash Network** -- `SharedHashService` (NIP-56 Kind 1984 report events from relays), confidence aggregation, auto-promotion to CSAM entries
4. **B.4: Authority Reporting** -- `AuthorityReportGenerator`, Authority Report screen, NIP-56 report event publishing, `HiddenAttachmentRecords` Drift table

---

### Phase C: Message Integrity

**Dependencies:** Phase A

1. **C.1: Message Signatures** -- Schnorr signatures on all messages via Nostr event serialization (already integrated in message services)
2. **C.2: E2EE DMs** -- NIP-44 encryption/decryption in `DmService`, on-device scanning post-decryption

---

### Phase D: Monetization + Verification

**Dependencies:** Phase A

**Deliverables:**
- `PaymentRecords`, `PaymentConfig` Drift tables
- `StripePaymentService` (Checkout via URL launcher + deep-link callback)
- `ZapPaymentService` (NIP-57 zap request + receipt monitoring)
- `VerificationPaymentService`
- Payment UI screens
- `VerifiedUserBenefits` Drift table + `UserBenefitsService`
- `CustomThemes` Drift table

---

### Phase E: App Updates

**Dependencies:** None (standalone)

**Deliverables:**
- `AppUpdateService` (GitHub Releases API, platform-specific download + apply) -- already implemented
- `AppUpdateProvider` (unified Riverpod provider for desktop + mobile)
- Dashboard update banner UI

---

### Dependency Graph

```
Phase A: Audit Logging
    |
    +-- Phase B: Content Safety (B.1 -> B.2 -> B.3 -> B.4)
    |
    +-- Phase C: Message Integrity (C.1 -> C.2)
    |
    +-- Phase D: Monetization + Verification

Phase E: App Updates (independent)
```

### Dart Packages

| Package | Phase | Purpose |
|---------|-------|---------|
| `image` | B.1 | Pure Dart image decoding for dHash computation |
| ONNX Runtime (FFI) | B.2 | On-device NSFW model inference |
| `url_launcher` | D | Open Stripe Checkout in browser |
| `uni_links` / `app_links` | D | Deep-link callback from Stripe |
| `package_info_plus` | E | Read current app version for update comparison |
