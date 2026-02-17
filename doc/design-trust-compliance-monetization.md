# Trust, Compliance & Monetization — Design Document

This document covers the design for eight interconnected systems that build on the existing federation architecture (see `doc/architecture-cross-instance.md`). Each system has its own database schema, models, services, and controllers, but they share integration points described at the end.

---

## Table of Contents

1. [Audit Logging & Legal Compliance](#1-audit-logging--legal-compliance)
1.5. [Content Safety: CSAM Detection, Upload Scanning & Bad Actor Handling](#15-content-safety-csam-detection-upload-scanning--bad-actor-handling)
1.6. [Federation Security: Threat Model & Cryptographic Protections](#16-federation-security-threat-model--cryptographic-protections)
2. [Trust / Reputation Tier System](#2-trust--reputation-tier-system)
3. [Rate Limiting by Tier](#3-rate-limiting-by-tier)
4. [API Versioning](#4-api-versioning)
5. [Monetization (Stripe + Zaps)](#5-monetization-stripe--zaps)
6. [App Updates](#6-app-updates)
7. [Integration Points](#7-integration-points)
8. [Phased Implementation Order](#8-phased-implementation-order)

---

## 1. Audit Logging & Legal Compliance

### Purpose

Provide an immutable record of federation events, user activity, and moderation actions for legal compliance, evidence preservation, and instance administration.

### Database Schema

#### `federation_audit_logs`

Records every cross-instance interaction.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `event_type` | `string` | `auth_attempt`, `auth_success`, `auth_failure`, `domain_block`, `domain_unblock`, `token_issued`, `token_revoked`, `profile_sync`, `membership_report`, `friend_request_sent`, `friend_request_received`, `server_created_remote` |
| `actor_type` | `string` | Polymorphic: `User`, `RemoteUser`, `System` |
| `actor_id` | `bigint` | Polymorphic ID (nullable for system events) |
| `target_type` | `string` | Polymorphic: `User`, `RemoteUser`, `InstanceBlocklist`, `Server` |
| `target_id` | `bigint` | Polymorphic ID (nullable) |
| `remote_domain` | `string` | The remote instance domain involved |
| `ip_address` | `inet` | Request IP (stored for auth events) |
| `metadata` | `jsonb` | Freeform context (challenge nonce, error message, etc.) |
| `created_at` | `datetime` | Immutable timestamp |

**Indexes:**
- `(event_type, created_at)` — filter by type with time range
- `(actor_type, actor_id)` — look up all events for a user
- `(remote_domain, created_at)` — look up all events for an instance
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

**Indexes:**
- `(holdable_type, holdable_id)` unique where `active = true` — one active hold per target
- `(placed_by_id)`

#### `data_exports`

Tracks GDPR / data subject access requests.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `user_id` | `bigint` | FK → `users` |
| `requested_by_id` | `bigint` | FK → `users` (admin or self) |
| `export_type` | `string` | `full`, `messages`, `profile`, `audit_log` |
| `status` | `string` | `pending`, `processing`, `completed`, `failed`, `expired` |
| `file_path` | `string` | Path to generated archive (encrypted at rest) |
| `expires_at` | `datetime` | Auto-delete after download window |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(user_id, status)`
- `(status)` — for background job polling

#### `domain_block_snapshots`

Preserves evidence when a domain is blocked (captures state of remote users, active sessions, etc.).

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `instance_blocklist_id` | `bigint` | FK → `instance_blocklists` |
| `snapshot_data` | `jsonb` | Serialized state: remote user count, active sessions, server memberships, recent auth events |
| `created_at` | `datetime` | |

**Indexes:**
- `(instance_blocklist_id)` unique

### New Models

| Model | File | Purpose |
|-------|------|---------|
| `FederationAuditLog` | `app/models/federation_audit_log.rb` | Write-once audit record. No `update` or `destroy`. Validates presence of `event_type`. |
| `LegalHold` | `app/models/legal_hold.rb` | Polymorphic hold with `active` scope. `place!` and `lift!` instance methods. |
| `DataExport` | `app/models/data_export.rb` | State machine: `pending` → `processing` → `completed`/`failed`. Has attached archive via Active Storage. |
| `DomainBlockSnapshot` | `app/models/domain_block_snapshot.rb` | Created automatically when an `InstanceBlocklist` record is created. |

### New Services

| Service | File | Purpose |
|---------|------|---------|
| `AuditService` | `app/services/audit_service.rb` | Central logging method: `AuditService.log(event_type:, actor:, target:, remote_domain:, ip_address:, metadata:)`. Called from controllers, services, and jobs. |
| `DataExportService` | `app/services/data_export_service.rb` | Generates ZIP archive of user data. Runs as a Sidekiq job. Includes messages, profile, attachments, audit log entries. Encrypts archive with instance key. |
| `DomainBlockSnapshotService` | `app/services/domain_block_snapshot_service.rb` | On domain block: snapshots remote user count, active sessions, server memberships. Called from `InstanceBlocklist` `after_create` callback. |

### New Controllers

| Controller | File | Routes | Purpose |
|------------|------|--------|---------|
| `Admin::AuditLogsController` | `app/controllers/admin/audit_logs_controller.rb` | `GET /admin/audit_logs` | Paginated, filterable log viewer |
| `Admin::LegalHoldsController` | `app/controllers/admin/legal_holds_controller.rb` | `GET/POST/DELETE /admin/legal_holds` | Manage legal holds |
| `Admin::DataExportsController` | `app/controllers/admin/data_exports_controller.rb` | `GET/POST /admin/data_exports` | Initiate and download exports |

### Modified Existing Files

| File | Change |
|------|--------|
| `app/models/instance_blocklist.rb` | Add `after_create :create_snapshot` callback that calls `DomainBlockSnapshotService` |
| `app/controllers/nostr/auth_controller.rb` | Add `AuditService.log` calls on auth attempt, success, failure |
| `app/services/federation_service.rb` | Add `AuditService.log` calls on remote server creation, profile fetch, friend request |
| `app/services/federation_token_service.rb` | Add `AuditService.log` on token generation and verification failure |
| `app/jobs/prune_messages_job.rb` | Check `LegalHold.active.where(holdable: user_or_server)` before pruning — skip held records |
| `config/routes.rb` | Add admin routes for audit logs, legal holds, data exports |

### Flow: Domain Block with Evidence Preservation

```
Admin clicks "Block domain"
        │
        ▼
InstanceBlocklist.create!(domain: "spam.chat", ...)
        │
        ├── after_create :create_snapshot
        │       │
        │       ▼
        │   DomainBlockSnapshotService.call(blocklist_entry)
        │       │
        │       ├── Count RemoteUser.where(home_instance: domain)
        │       ├── Gather active sessions / server memberships
        │       ├── Gather last 100 FederationAuditLog entries for domain
        │       └── Save as DomainBlockSnapshot (jsonb)
        │
        ├── AuditService.log(event_type: "domain_block", ...)
        │
        └── Revoke active sessions for blocked domain
                │
                ▼
        RemoteUser sessions from domain are invalidated
```

---

## 1.5 Content Safety: CSAM Detection, Upload Scanning & Bad Actor Handling

### Purpose

Detect, quarantine, and report child sexual abuse material (CSAM) to comply with US federal law (18 U.S.C. 2258A). Provide instance-wide user suspension, enhanced moderation workflows, and federation mechanisms to notify peer instances about bad actors. This system must be operational before federation goes live.

### Legal Context

Electronic service providers that obtain knowledge of CSAM must report it to the National Center for Missing & Exploited Children (NCMEC) via the CyberTipline. Failure to report is a federal offense. Requirements:
- The image/video content must be preserved (not deleted)
- Any identifying information about the uploader (IP, account info) must be included
- Date/time of upload must be recorded
- Evidence must be preserved for at least 90 days

### Database Schema

#### `content_hashes`

Perceptual hash (pHash) and SHA-256 of every uploaded image blob.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `hashable_type` | `string` | Polymorphic: `ActiveStorage::Blob`, `Message`, `ServerEmoji`, `ServerSticker` |
| `hashable_id` | `bigint` | Polymorphic ID |
| `blob_id` | `bigint` | FK → `active_storage_blobs` |
| `sha256` | `string(64)` | SHA-256 hex digest of original file |
| `phash` | `string(16)` | 64-bit perceptual hash (dHash via `dhash-vips`) |
| `phash_fingerprint` | `bit(64)` | Binary representation for Hamming distance queries |
| `match_status` | `string` | `clean`, `matched`, `pending_review` — default `pending_review` during scan |
| `matched_known_bad_hash_id` | `bigint` | FK → `known_bad_hashes` (nullable, set on match) |
| `scanned_at` | `datetime` | When the scan completed |
| `created_at` | `datetime` | |

**Indexes:**
- `(sha256)` — exact duplicate lookup
- `(phash)` — perceptual similarity lookup
- `(blob_id)` unique
- `(hashable_type, hashable_id)` — find hash for a record
- `(match_status)` — filter matched/pending

#### `known_bad_hashes`

Database of known-bad hashes seeded from NCMEC, Project VIC, peer instances, or local confirmed matches.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `hash_type` | `string` | `sha256`, `phash` |
| `hash_value` | `string` | The hash value |
| `source` | `string` | `ncmec`, `project_vic`, `peer_instance`, `local_confirmed` |
| `source_identifier` | `string` | Source-specific ID (NCMEC hash ID, peer domain, etc.) |
| `severity` | `string` | `confirmed_csam`, `suspected`, `non_photographic` |
| `added_at` | `datetime` | When this hash was added to the database |
| `added_by_id` | `bigint` | FK → `users` (admin, nullable for imports) |
| `active` | `boolean` | Default `true` — can deactivate false positives |
| `created_at` | `datetime` | |

**Indexes:**
- `(hash_type, hash_value)` unique — fast lookup
- `(source)`
- `(active)` — filter active hashes

#### `quarantined_uploads`

Metadata for uploads that matched a known-bad hash. Content is preserved under legal hold but hidden from users.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `content_hash_id` | `bigint` | FK → `content_hashes` |
| `blob_id` | `bigint` | FK → `active_storage_blobs` |
| `uploader_type` | `string` | Polymorphic: `User`, `RemoteUser` |
| `uploader_id` | `bigint` | Polymorphic ID |
| `uploader_ip` | `inet` | IP address at time of upload |
| `original_record_type` | `string` | What the upload was attached to: `Message`, `ServerEmoji`, etc. |
| `original_record_id` | `bigint` | Polymorphic ID |
| `matched_hash_id` | `bigint` | FK → `known_bad_hashes` |
| `match_type` | `string` | `exact_sha256`, `perceptual_phash` |
| `match_distance` | `integer` | Hamming distance for pHash matches (0 = exact, higher = less similar) |
| `status` | `string` | `quarantined`, `confirmed_csam`, `false_positive`, `reported_to_ncmec` |
| `moderation_report_id` | `bigint` | FK → `moderation_reports` (auto-created) |
| `legal_hold_id` | `bigint` | FK → `legal_holds` (auto-created) |
| `auto_suspended` | `boolean` | Whether this triggered an automatic user suspension |
| `reviewed_by_id` | `bigint` | FK → `users` (admin who reviewed) |
| `reviewed_at` | `datetime` | When admin reviewed |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(content_hash_id)` unique
- `(blob_id)` unique
- `(uploader_type, uploader_id)` — find all quarantined uploads by user
- `(status)` — filter by review status
- `(moderation_report_id)`
- `(created_at)` — chronological review queue

#### `ncmec_reports`

Tracks CyberTipline submissions to NCMEC.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `report_id` | `string` | NCMEC-assigned report ID (set after submission) |
| `status` | `string` | `draft`, `submitted`, `accepted`, `rejected`, `requires_revision` |
| `reported_by_id` | `bigint` | FK → `users` (admin who initiated or system) |
| `suspect_user_type` | `string` | Polymorphic: `User`, `RemoteUser` |
| `suspect_user_id` | `bigint` | Polymorphic ID |
| `suspect_ip` | `inet` | IP address of suspect at time of incident |
| `incident_datetime` | `datetime` | When the content was uploaded |
| `incident_summary` | `text` | Description of the incident |
| `provider_id` | `string` | NCMEC-assigned provider ID for this instance |
| `submission_payload` | `jsonb` | Full XML/JSON payload sent to NCMEC API |
| `response_payload` | `jsonb` | NCMEC API response |
| `submitted_at` | `datetime` | When submitted to NCMEC |
| `response_received_at` | `datetime` | When NCMEC responded |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(report_id)` unique where not null
- `(status)`
- `(suspect_user_type, suspect_user_id)` — all reports for a suspect
- `(created_at)` — chronological order

#### `ncmec_report_attachments`

Join table linking NCMEC reports to quarantined uploads.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `ncmec_report_id` | `bigint` | FK → `ncmec_reports` |
| `quarantined_upload_id` | `bigint` | FK → `quarantined_uploads` |
| `file_id` | `string` | NCMEC-assigned file ID after upload |
| `created_at` | `datetime` | |

**Indexes:**
- `(ncmec_report_id, quarantined_upload_id)` unique
- `(quarantined_upload_id)`

#### `user_suspensions`

Instance-wide user suspensions (temporary or permanent).

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `user_id` | `bigint` | FK → `users` |
| `suspension_type` | `string` | `temporary`, `permanent` |
| `reason` | `text` | Human-readable reason |
| `reason_category` | `string` | `csam`, `spam`, `harassment`, `illegal`, `admin_action`, `federation_received` |
| `auto_triggered` | `boolean` | Whether this was triggered automatically by the scanning pipeline |
| `triggered_by_quarantine_id` | `bigint` | FK → `quarantined_uploads` (nullable) |
| `suspended_by_id` | `bigint` | FK → `users` (admin, nullable for auto) |
| `expires_at` | `datetime` | Null for permanent suspensions |
| `lifted_at` | `datetime` | When lifted (null if active) |
| `lifted_by_id` | `bigint` | FK → `users` (admin who lifted) |
| `lift_reason` | `text` | Why the suspension was lifted |
| `federation_broadcast_status` | `string` | `pending`, `broadcasting`, `completed`, `not_applicable` |
| `federation_broadcast_at` | `datetime` | When federation notification was sent |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(user_id, lifted_at)` — find active suspensions (lifted_at IS NULL)
- `(suspension_type)`
- `(reason_category)`
- `(expires_at)` where `lifted_at IS NULL` — for `LiftExpiredSuspensionsJob`
- `(federation_broadcast_status)`
- `(created_at)`

#### `federation_suspension_notifications`

Outgoing and incoming suspension notifications between federated instances.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `direction` | `string` | `outgoing`, `incoming` |
| `user_suspension_id` | `bigint` | FK → `user_suspensions` (for outgoing) |
| `remote_domain` | `string` | The federated instance domain |
| `suspended_pubkey` | `string` | The nostr public key of the suspended user |
| `reason_category` | `string` | `csam`, `spam`, `harassment`, `illegal` |
| `reason_summary` | `text` | Brief description (no sensitive content details) |
| `status` | `string` | `pending`, `sent`, `delivered`, `failed`, `received`, `acted_upon`, `ignored` |
| `action_taken` | `string` | For incoming: `auto_suspended`, `flagged_for_review`, `ignored`, `already_suspended` |
| `trust_tier_impact` | `string` | `none`, `demoted`, `blocklisted` — what happened to the sending/receiving instance's tier |
| `nostr_event_id` | `string` | NIP-56 event ID if applicable |
| `delivered_at` | `datetime` | |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(direction, status)` — pending outgoing notifications
- `(remote_domain, created_at)` — history per domain
- `(suspended_pubkey)` — find all notifications for a pubkey
- `(user_suspension_id)` — link back to suspension

### Modified Existing Tables

#### `users` — add suspension support

| Column | Type | Description |
|--------|------|-------------|
| `suspended_at` | `datetime` | Denormalized from `user_suspensions` — set on suspend, cleared on lift. Used by Devise `active_for_authentication?` for O(1) auth check. |

#### `moderation_reports` — add priority and escalation

| Column | Type | Description |
|--------|------|-------------|
| `priority` | `integer` | `0` (normal), `1` (elevated), `2` (urgent/CSAM) — default `0` |
| `escalated` | `boolean` | Whether this report has been escalated to all admins — default `false` |
| `escalated_at` | `datetime` | When escalation occurred |

**Additional change:** Add `csam` to `REPORT_TYPES` constant (alongside existing `spam`, `illegal`, `impersonation`, `harassment`, `other`).

#### `instance_configs` — add content safety settings

| Column | Type | Description |
|--------|------|-------------|
| `upload_scanning_enabled` | `boolean` | Enable/disable the scanning pipeline — default `false` |
| `phash_threshold` | `integer` | Hamming distance threshold for perceptual match (default `10`, lower = stricter) |
| `auto_quarantine_enabled` | `boolean` | Auto-quarantine matched uploads — default `true` |
| `auto_suspend_on_csam` | `boolean` | Auto-suspend user on CSAM match — default `true` |
| `ncmec_api_enabled` | `boolean` | Enable NCMEC CyberTipline reporting — default `false` |
| `ncmec_provider_id` | `string` | NCMEC-assigned provider ID for this instance |
| `csam_escalation_hours` | `integer` | Hours before unresolved CSAM reports escalate to all admins — default `4` |
| `federation_suspension_broadcast_enabled` | `boolean` | Broadcast suspensions to federated instances — default `true` |
| `federation_suspension_auto_action` | `string` | What to do with incoming suspension notifications: `auto_suspend`, `flag_for_review`, `ignore` — default `flag_for_review` |

### New Models

| Model | File | Purpose |
|-------|------|---------|
| `ContentHash` | `app/models/content_hash.rb` | Polymorphic hash record for uploaded images. Scopes: `matched`, `clean`, `pending_review`. Belongs to `KnownBadHash` (optional). Validates uniqueness on `blob_id`. |
| `KnownBadHash` | `app/models/known_bad_hash.rb` | Known-bad hash entry. Scopes: `active`, `by_source`, `by_severity`. Class method: `match?(sha256:, phash:, threshold:)` returns the matching record or nil. |
| `QuarantinedUpload` | `app/models/quarantined_upload.rb` | Quarantined upload metadata. Belongs to `ContentHash`, `KnownBadHash`, `ModerationReport`, `LegalHold`. Scopes: `pending_review`, `confirmed`, `false_positive`. State machine: `quarantined` → `confirmed_csam` / `false_positive` → `reported_to_ncmec`. |
| `NcmecReport` | `app/models/ncmec_report.rb` | CyberTipline report tracker. Has many `NcmecReportAttachment`. State machine: `draft` → `submitted` → `accepted` / `rejected`. Validates presence of `incident_summary` and `suspect_user`. |
| `NcmecReportAttachment` | `app/models/ncmec_report_attachment.rb` | Join between `NcmecReport` and `QuarantinedUpload`. |
| `UserSuspension` | `app/models/user_suspension.rb` | Instance-wide suspension. Scopes: `active` (not lifted), `expired` (past `expires_at`), `auto_triggered`, `by_category`. Methods: `lift!(admin, reason)`, `active?`, `permanent?`. Callbacks: on create sets `user.suspended_at`, on lift clears it. |
| `FederationSuspensionNotification` | `app/models/federation_suspension_notification.rb` | Cross-instance suspension notification. Scopes: `outgoing_pending`, `incoming_unprocessed`. Methods: `mark_delivered!`, `mark_acted_upon!(action)`. |

### New Concerns

| Concern | File | Purpose |
|---------|------|---------|
| `Suspendable` | `app/models/concerns/suspendable.rb` | Mixed into `User`. Overrides Devise `active_for_authentication?` to return `false` when `suspended_at` is present. Adds `suspended?` method, `active` / `suspended` scopes, and `inactive_message` override for "Your account has been suspended" error. |
| `ScannableUpload` | `app/controllers/concerns/scannable_upload.rb` | `after_action` on controllers that handle image uploads (messages, emojis, stickers). Detects newly attached image blobs and enqueues `UploadScanJob` for each. Only active when `InstanceConfig.current.upload_scanning_enabled?`. |

### New Services

| Service | File | Purpose |
|---------|------|---------|
| `UploadScanService` | `app/services/upload_scan_service.rb` | Computes SHA-256 and pHash (via `dhash-vips`) for an image blob. Checks against `KnownBadHash` database. Returns match result. Creates `ContentHash` record. |
| `QuarantineService` | `app/services/quarantine_service.rb` | Orchestrates quarantine: hides the content, creates `QuarantinedUpload` record, auto-creates `ModerationReport` (type: `csam`, priority: 2), auto-creates `LegalHold`, optionally auto-suspends user via `UserSuspensionService`. Calls `AuditService.log`. |
| `NcmecReportService` | `app/services/ncmec_report_service.rb` | Builds and submits CyberTipline reports. Creates XML payload per NCMEC API spec, uploads evidence files, submits report, tracks response. Called from admin UI or automatically after quarantine confirmation. |
| `UserSuspensionService` | `app/services/user_suspension_service.rb` | Suspends or lifts suspension on a user. On suspend: sets `user.suspended_at`, invalidates all active sessions, hides user content via query scope (not deletion), enqueues `FederationSuspensionBroadcastJob`. On lift: clears `suspended_at`, re-enables content visibility. Calls `AuditService.log`. |
| `ContentHashImportService` | `app/services/content_hash_import_service.rb` | Bulk import known-bad hashes from NCMEC hash lists, Project VIC CSV exports, or peer instance hash shares. Validates format, deduplicates, creates `KnownBadHash` records in batches. |
| `FederationSuspensionService` | `app/services/federation_suspension_service.rb` | Broadcasts suspension notifications to federated instances (outgoing). Processes incoming suspension notifications: checks trust tier of sending instance, applies configured auto-action (`auto_suspend`, `flag_for_review`, `ignore`), optionally adjusts sender's trust tier. |
| `CsamEscalationService` | `app/services/csam_escalation_service.rb` | Finds `ModerationReport` records with `report_type: csam` that are unresolved for longer than `csam_escalation_hours`. Marks as escalated, sends `AdminMailer#csam_escalation` to all instance admins. |

### New Jobs

| Job | File | Purpose |
|-----|------|---------|
| `UploadScanJob` | `app/jobs/upload_scan_job.rb` | Async wrapper for `UploadScanService`. Receives blob ID, calls scan, calls `QuarantineService` if match found. Retries with backoff on transient errors. |
| `NcmecReportJob` | `app/jobs/ncmec_report_job.rb` | Async wrapper for `NcmecReportService.submit`. Receives `NcmecReport` ID, submits to CyberTipline API, updates status. Retries on API errors. |
| `CsamEscalationJob` | `app/jobs/csam_escalation_job.rb` | Recurring job (every 30 minutes via Solid Queue). Calls `CsamEscalationService` to escalate overdue CSAM reports. |
| `FederationSuspensionBroadcastJob` | `app/jobs/federation_suspension_broadcast_job.rb` | Sends suspension notification to all federated peer instances. Creates `FederationSuspensionNotification` for each peer. Retries failed deliveries. |
| `LiftExpiredSuspensionsJob` | `app/jobs/lift_expired_suspensions_job.rb` | Recurring job (hourly via Solid Queue). Finds `UserSuspension` records where `expires_at < Time.current` and `lifted_at IS NULL`, calls `UserSuspensionService.lift!` for each. |

### New Controllers

| Controller | File | Routes | Purpose |
|------------|------|--------|---------|
| `Admin::UserSuspensionsController` | `app/controllers/admin/user_suspensions_controller.rb` | `GET/POST/DELETE /admin/user_suspensions` | View, create, and lift user suspensions. Shows suspension history. |
| `Admin::QuarantinedUploadsController` | `app/controllers/admin/quarantined_uploads_controller.rb` | `GET /admin/quarantined_uploads`, `PATCH /admin/quarantined_uploads/:id` | Review queue for quarantined uploads. Confirm as CSAM or mark false positive. One-click CSAM action panel. |
| `Admin::NcmecReportsController` | `app/controllers/admin/ncmec_reports_controller.rb` | `GET/POST /admin/ncmec_reports` | View and submit NCMEC CyberTipline reports. Track submission status. |
| `Admin::KnownBadHashesController` | `app/controllers/admin/known_bad_hashes_controller.rb` | `GET/POST/DELETE /admin/known_bad_hashes` | Manage known-bad hash database. Import from file. View match statistics. |
| `Admin::ContentSafetyConfigController` | `app/controllers/admin/content_safety_config_controller.rb` | `GET/PATCH /admin/content_safety_config` | Configure scanning settings, NCMEC credentials, escalation thresholds, federation suspension behavior. |
| `Federation::SuspensionsController` | `app/controllers/federation/suspensions_controller.rb` | `POST /federation/suspensions/notify` | Receive incoming suspension notifications from federated instances. Validates federation token. Applies configured auto-action. |

### New Mailer

| Mailer | Method | Purpose |
|--------|--------|---------|
| `AdminMailer` | `#csam_escalation(report)` | Urgent email to all instance admins when a CSAM moderation report has been unresolved for longer than `csam_escalation_hours`. Includes report ID, age, and link to admin review panel. Subject: "[URGENT] Unresolved CSAM report requires immediate action". |

### New Gem

| Gem | Purpose |
|-----|---------|
| `dhash-vips` | Perceptual hashing (dHash) via `ruby-vips`. Reuses the existing `image_processing` gem's vips bindings — no new native C dependency. Produces a 64-bit hash that allows Hamming distance comparison for detecting resized, cropped, or re-encoded variants of the same image. |

### Modified Existing Files

| File | Change |
|------|--------|
| `app/models/user.rb` | Include `Suspendable` concern. Add `has_many :user_suspensions`. |
| `app/models/moderation_report.rb` | Add `csam` to `REPORT_TYPES`. Add `priority` and `escalated` attributes. Add `csam` scope. Default `priority: 2` when `report_type: "csam"`. |
| `app/models/instance_config.rb` | Add content safety config attributes (scanning toggles, NCMEC config, escalation settings, federation suspension settings). |
| `app/controllers/messages_controller.rb` | Include `ScannableUpload` concern. Add content type validation on file attachments — reject non-image/video/audio/document MIME types. |
| `app/controllers/server_emojis_controller.rb` | Include `ScannableUpload` concern (emojis are already validated but should also be scanned). |
| `app/controllers/server_stickers_controller.rb` | Include `ScannableUpload` concern. |
| `Gemfile` | Add `gem "dhash-vips"`. |
| `config/routes.rb` | Add admin content safety routes and federation suspensions route. |
| `config/recurring.yml` | Add `csam_escalation` schedule (every 30 min) and `lift_expired_suspensions` schedule (hourly). |

### Flow 1: Upload Scanning Pipeline

```
User uploads image in message
        │
        ▼
MessagesController#create (includes ScannableUpload)
        │
        ├── Content type validation
        │     ├── Allowed MIME type? → continue
        │     └── Disallowed type? → reject with error
        │
        ├── Save message normally
        │
        └── after_action: ScannableUpload detects new image blob(s)
                │
                ├── InstanceConfig.current.upload_scanning_enabled? → no → done
                │
                └── yes → UploadScanJob.perform_later(blob_id)
                        │
                        ▼
                UploadScanService.call(blob)
                        │
                        ├── Download blob to tempfile
                        ├── Compute SHA-256 digest
                        ├── Compute pHash via dhash-vips
                        ├── Create ContentHash record
                        │
                        ├── KnownBadHash.match?(sha256:, phash:, threshold:)
                        │     │
                        │     ├── No match → ContentHash.update!(match_status: "clean")
                        │     │               → done
                        │     │
                        │     └── Match found!
                        │           │
                        │           ▼
                        │     ContentHash.update!(match_status: "matched",
                        │                         matched_known_bad_hash_id: match.id)
                        │           │
                        │           ▼
                        │     QuarantineService.call(content_hash, match)
                        │           │
                        │           ├── Hide content (set message.hidden = true)
                        │           ├── Create QuarantinedUpload record
                        │           ├── Create ModerationReport (type: csam, priority: 2)
                        │           ├── Create LegalHold (90-day minimum)
                        │           ├── AuditService.log(event_type: "csam_match_detected")
                        │           │
                        │           ├── auto_suspend_on_csam enabled?
                        │           │     └── yes → UserSuspensionService.suspend!(user,
                        │           │                 reason_category: "csam",
                        │           │                 auto_triggered: true)
                        │           │
                        │           └── done — awaiting admin review
                        │
                        └── Cleanup tempfile
```

### Flow 2: NCMEC CyberTipline Reporting

```
Admin reviews quarantined upload in /admin/quarantined_uploads
        │
        ▼
Clicks "Confirm as CSAM"
  → QuarantinedUpload.update!(status: "confirmed_csam")
        │
        ▼
Clicks "Report to NCMEC" (or auto-triggered after confirmation)
        │
        ▼
NcmecReportService.build(quarantined_upload)
        │
        ├── Create NcmecReport (status: "draft")
        ├── Create NcmecReportAttachment linking to quarantined upload
        ├── Build incident summary from:
        │     - Upload metadata (timestamp, IP, user info)
        │     - Hash match details
        │     - Any related ModerationReport context
        │
        ├── Admin reviews draft, optionally edits summary
        │
        ▼
Admin clicks "Submit to NCMEC"
  → NcmecReportJob.perform_later(ncmec_report.id)
        │
        ▼
NcmecReportService.submit(ncmec_report)
        │
        ├── Validate InstanceConfig.current.ncmec_api_enabled?
        ├── Validate InstanceConfig.current.ncmec_provider_id present
        │
        ├── POST to NCMEC CyberTipline API:
        │     1. Initialize report → get report token
        │     2. Upload file(s) from quarantined_uploads
        │     3. Add incident details (IP, timestamp, user info)
        │     4. Finalize report
        │
        ├── On success:
        │     ├── NcmecReport.update!(status: "submitted", report_id: <ncmec_id>)
        │     ├── QuarantinedUpload.update!(status: "reported_to_ncmec")
        │     └── AuditService.log(event_type: "ncmec_report_submitted")
        │
        └── On failure:
              ├── NcmecReport.update!(status: "requires_revision",
              │                       response_payload: error)
              └── Retry via NcmecReportJob (with backoff)
```

### Flow 3: Instance-Wide User Suspension

```
Admin clicks "Suspend User" (or auto-triggered by CSAM match)
        │
        ▼
UserSuspensionService.suspend!(user, params)
        │
        ├── Create UserSuspension record
        │     (type, reason, category, auto_triggered, expires_at)
        │
        ├── Set user.suspended_at = Time.current
        │     (denormalized for Devise auth check)
        │
        ├── Invalidate all active sessions
        │     └── user.update!(current_sign_in_token: nil)
        │         + clear all session records for user
        │         → user is immediately logged out everywhere
        │
        ├── Hide user content via query scope
        │     └── NOT deleted — preserved for evidence / law enforcement
        │     └── Messages, server memberships remain in DB
        │     └── Query scopes filter suspended users from:
        │           - Member lists
        │           - Message author display (shows "[suspended user]")
        │           - Profile lookups
        │
        ├── AuditService.log(event_type: "user_suspended")
        │
        ├── federation_suspension_broadcast_enabled?
        │     └── yes → FederationSuspensionBroadcastJob.perform_later(suspension.id)
        │               │
        │               ▼
        │         For each federated peer instance:
        │               ├── POST /federation/suspensions/notify
        │               │     { pubkey: "...", reason_category: "csam",
        │               │       reason_summary: "...", nostr_event_id: "..." }
        │               ├── Create FederationSuspensionNotification
        │               │     (direction: outgoing)
        │               └── Track delivery status
        │
        └── done
              │
              ▼
Suspended user tries to log in
        │
        ▼
Devise calls user.active_for_authentication?
        │
        ├── Suspendable concern checks: user.suspended_at.present?
        │     └── yes → return false
        │         → Devise shows: "Your account has been suspended."
        │
        └── no → normal auth flow
```

### Flow 4: Enhanced Moderation Report Workflow

```
Report queue: /admin/moderation_reports
  (sorted by priority DESC, created_at ASC)
        │
        ├── Priority 2 (urgent): CSAM reports — red badge, always at top
        ├── Priority 1 (elevated): auto-escalated or manually escalated
        └── Priority 0 (normal): spam, harassment, etc.
        │
        ▼
Admin opens a CSAM report (priority 2)
        │
        ▼
Shows "One-Click CSAM Action Panel":
┌──────────────────────────────────────────────────────┐
│  ⚠ CSAM Report — Immediate Action Required           │
│                                                       │
│  Uploader: @suspect_user (IP: 1.2.3.4)               │
│  Upload time: 2024-01-15 14:32 UTC                    │
│  Hash match: SHA-256 exact (NCMEC source)             │
│  Current status: Quarantined, user auto-suspended     │
│                                                       │
│  [Take All Actions] ← single click does all below:   │
│    ✓ Confirm as CSAM                                  │
│    ✓ Suspend user (permanent)                         │
│    ✓ Place legal hold (90 days)                       │
│    ✓ Create NCMEC report (draft)                      │
│    ✓ Broadcast NIP-56 report to relays                │
│    ✓ Block user's home domain (if remote)             │
│    ✓ Close all other reports for this user             │
│                                                       │
│  Or take individual actions:                          │
│  [Confirm CSAM] [Suspend] [NCMEC Report]             │
│  [False Positive — Release]                           │
└──────────────────────────────────────────────────────┘
        │
        ▼
Admin clicks "Take All Actions"
        │
        ├── QuarantinedUpload.update!(status: "confirmed_csam")
        ├── UserSuspensionService.suspend!(user,
        │     type: "permanent", reason_category: "csam")
        ├── LegalHold already exists (auto-created) — verify 90-day minimum
        ├── NcmecReportService.build(quarantined_upload) → creates draft
        ├── Publish NIP-56 report event to connected relays
        ├── If remote user:
        │     InstanceBlocklist.create!(domain: user.home_instance)
        ├── ModerationReport.where(target: user).pending
        │     .update_all(status: "resolved")
        └── AuditService.log(event_type: "csam_one_click_action")
```

### Flow 5: Federation Suspension Propagation

```
Instance A suspends user for CSAM → broadcasts to peers
        │
        ▼
Instance B receives: POST /federation/suspensions/notify
        │
        ▼
Federation::SuspensionsController#notify
        │
        ├── Validate federation token (existing auth)
        │
        ├── Check sending instance's trust tier
        │     ├── Tier 0 (blocklisted) → reject, ignore
        │     ├── Tier 3 (untrusted) → flag for review, do not auto-act
        │     ├── Tier 2 (standard) → apply configured auto-action
        │     └── Tier 1 (verified) → apply configured auto-action
        │
        ├── Create FederationSuspensionNotification (direction: incoming)
        │
        ├── Apply InstanceConfig.current.federation_suspension_auto_action:
        │
        │     "auto_suspend":
        │       └── Does user exist locally (by pubkey)?
        │             ├── yes → UserSuspensionService.suspend!(user,
        │             │           reason_category: "federation_received",
        │             │           reason: "Suspended on [domain] for [reason]")
        │             └── no → store notification for future reference
        │
        │     "flag_for_review":
        │       └── Create ModerationReport for admin review
        │           with link to federation notification details
        │
        │     "ignore":
        │       └── Log receipt but take no action
        │
        ├── Trust tier impact (for CSAM category):
        │     ├── If sender is Tier 1/2 and this is their 1st CSAM
        │     │     suspension → no tier change
        │     ├── If sender has sent 3+ CSAM suspensions in 30 days
        │     │     → flag for tier review (could indicate compromised
        │     │       instance or abuse of the notification system)
        │     └── If category is "csam" → always process regardless
        │           of auto-action setting (legal compliance overrides
        │           the "ignore" setting for CSAM)
        │
        └── FederationSuspensionNotification.mark_acted_upon!(action)
```

### Key Design Decisions

1. **pHash + SHA-256 dual hashing**: Perceptual hashing catches resized, cropped, and re-encoded variants. Cryptographic hashing catches exact duplicates. Both are computed for every upload, giving maximum coverage.

2. **`dhash-vips` over `phashion`**: Reuses the existing `image_processing` gem's vips bindings (`ruby-vips`). No new native C dependency to compile. Produces a 64-bit dHash suitable for Hamming distance comparison.

3. **Separate `quarantined_uploads` table**: Rather than adding a flag to `active_storage_blobs`, a separate table provides a cleaner audit trail, avoids coupling to Rails internals, and allows rich metadata (match type, distances, review status) without polluting the blob table.

4. **Denormalized `suspended_at` on `users`**: Devise calls `active_for_authentication?` on every authenticated request. A join query to `user_suspensions` on every request is expensive. A denormalized `suspended_at` column gives O(1) auth checking and is kept in sync by `UserSuspensionService`.

5. **Lazy content hiding via query scope**: Suspended user content is hidden via query scopes, not eagerly deleted. This preserves evidence for law enforcement and NCMEC reporting. Content can be restored if a suspension is lifted (false positive).

6. **One-click CSAM action**: Combines suspend + hold + NCMEC report + NIP-56 + domain block + bulk-close reports into a single admin click. Reduces moderator fatigue and decision fatigue for clear-cut cases. Individual actions remain available for nuanced situations.

7. **Content type validation on message attachments**: Currently missing — emojis and stickers validate content types, but message file attachments do not. Adding MIME type validation prevents non-media files from being uploaded through the message attachment flow.

8. **CSAM overrides "ignore" federation setting**: Even if an instance configures `federation_suspension_auto_action: "ignore"`, incoming CSAM-category suspension notifications are always processed (at minimum flagged for review). Legal compliance requirements override instance preference.

9. **90-day evidence retention**: Legal holds auto-created for CSAM quarantines have a minimum 90-day retention period per 18 U.S.C. 2258A. Admins cannot lift these holds early without explicit override and audit log entry.

---

## 1.6 Federation Security: Threat Model & Cryptographic Protections

### Purpose

Define exactly what a rogue or modified federated instance can and cannot do to users on other instances, and specify the cryptographic mitigations that close each gap. This section provides the security foundation for trusting a decentralized federation where instance operators control their own code.

### Threat Model

#### What a rogue instance CANNOT do (existing protections)

| Attack | Why it fails | Code reference |
|--------|-------------|----------------|
| **Forge authentication as another user** | NIP-42 challenge-response requires a valid Schnorr signature from the user's private key. The instance never sees the signing key for remote users. | `nostr_auth_controller.rb` NIP-42 challenge flow |
| **Impersonate a user across instances** | Federation auth verifies the Nostr pubkey signature against the challenge nonce. A rogue instance cannot produce a valid signature for a key it doesn't hold. | `NostrEventService#verify_auth_event` |
| **Forge friend requests** | Friend request events are signed Nostr kind 1 events. The receiving instance verifies the signature against the claimed sender's pubkey. | `friend_requests_controller.rb` signature verification |
| **Access federation endpoints without valid token** | `MessageVerifier`-based federation tokens are signed with the issuing instance's `secret_key_base`. A rogue instance cannot forge tokens for another instance. | `FederationTokenService#generate` / `#verify` |

#### What a rogue instance CAN do (current vulnerabilities)

| Attack | Severity | Description |
|--------|----------|-------------|
| **Read plaintext DMs** | **HIGH** | Messages are stored as plaintext. A rogue instance operator with database access can read all DMs involving their users. |
| **Modify message content silently** | **HIGH** | Messages have no cryptographic signature. A rogue instance can alter message content in transit or at rest with no way for recipients to detect tampering. |
| **Push fake conversation references** | **MEDIUM** | `push_conversation_reference` checks the instance blocklist but does not verify that the conversation reference was actually created by the claimed participants. |
| **Bypass NIP-05 verification** | **MEDIUM** | NIP-05 verification failure is logged but does not block authentication. A rogue instance can claim any NIP-05 identifier without proving domain ownership. |
| **Exploit long-lived federation tokens** | **MEDIUM** | Federation tokens are valid for 30 days with no revocation mechanism. A compromised token grants full access for the remaining TTL. |
| **Decrypt all private keys with single secret** | **MEDIUM** | All user private keys are encrypted with the same `secret_key_base`. Compromising this single value decrypts every user's Nostr private key on the instance. |

### Current Protections

| Protection | Mechanism | What it covers |
|-----------|-----------|----------------|
| NIP-42 challenge-response | Schnorr signature over random nonce | Authentication — proves user holds the private key |
| Federation tokens | `ActiveSupport::MessageVerifier` with `secret_key_base` | Authorization — proves the request comes from a trusted instance |
| HTTPS transport | TLS encryption in transit | Network — prevents eavesdropping and MITM on the wire |
| Instance blocklist | `InstanceBlocklist` table + checks on all federation endpoints | Access control — blocks known-bad instances entirely |
| Private key encryption at rest | AES-256-GCM via `ActiveSupport::MessageEncryptor` | Storage — encrypted private keys in database |
| Friend request signatures | Nostr kind 1 signed events | Integrity — friend requests cannot be forged |

### Security Gaps

| Gap | Impact | Current code reference |
|-----|--------|----------------------|
| No message signatures | Content can be spoofed or tampered with — recipients cannot verify message integrity | `message.rb` has no `signature` column |
| No end-to-end encryption | Instance operators can read all DMs in plaintext | `conversation.rb` stores plaintext content |
| NIP-05 verification optional | Identity claims are unverified — users can claim `alice@example.com` without proof | `auth_controller.rb:114-117` logs but doesn't block |
| 30-day tokens, no revocation | Long credential exposure window — compromised tokens cannot be invalidated | `FederationTokenService::TOKEN_EXPIRY = 30.days` |
| Conversation references unverified | Fake DM entries can be injected into user conversation lists | `friend_requests_controller.rb:201-235` |
| Single `secret_key_base` for all private keys | Single point of compromise — one leaked secret decrypts all user keys | `has_nostr_identity.rb` encryption calls |

### Mitigation Layers

Three independent mitigation layers, ordered by priority and dependency:

---

#### Layer 1: Message Signatures (prevents content spoofing)

**Goal:** Every message carries a cryptographic signature that proves the author wrote that exact content. Recipients (and their instances) can verify integrity independently.

**Database changes — `messages` table:**

| Column | Type | Description |
|--------|------|-------------|
| `nostr_event_id` | `string` | Nostr event ID (SHA-256 hash of the serialized event) |
| `signature` | `string` | Schnorr signature of the event (hex-encoded, 128 chars) |

**New service: `MessageSigningService`**

```ruby
# app/services/message_signing_service.rb
class MessageSigningService
  # On message create: sign content as a Nostr kind 1 event
  def sign(message)
    # 1. Serialize message content as Nostr event (kind 1)
    # 2. Sign with author's private key (Schnorr/secp256k1)
    # 3. Store nostr_event_id + signature on the message record
  end

  # On message display from remote context: verify signature
  def verify(message)
    # 1. Re-serialize message content as Nostr event
    # 2. Verify signature against claimed author's pubkey
    # 3. Return true/false — UI shows verification badge or warning
  end
end
```

**Key design decision:** Sign ALL messages, not just cross-instance ones. This provides a universal integrity guarantee and simplifies the model — every message is verifiable, regardless of origin.

**Flow: Message Signing**

```
Author composes message
        │
        ▼
MessageSigningService.sign(message)
        │
        ├── Serialize as Nostr kind 1 event (pubkey, created_at, kind, tags, content)
        │
        ├── Compute event ID (SHA-256 of serialized event)
        │
        ├── Sign event ID with author's Schnorr private key
        │
        ├── Store nostr_event_id + signature on message record
        │
        ▼
Message saved to database with signature
        │
        ▼
Recipient's instance receives message (via federation or local)
        │
        ▼
MessageSigningService.verify(message)
        │
        ├── Re-serialize content as Nostr event
        │
        ├── Verify Schnorr signature against author's pubkey
        │
        ├── Signature valid? → display with verified badge
        │
        └── Signature invalid/missing? → display with unverified warning
```

---

#### Layer 2: NIP-44 Encrypted DMs (prevents snooping)

**Goal:** DM content is encrypted client-side so that only the conversation participants can read it. The server stores only ciphertext — instance operators see nothing.

**Database changes — `messages` table:**

| Column | Type | Description |
|--------|------|-------------|
| `encrypted_content` | `text` | NIP-44 ciphertext (for DM conversations only) |
| `encrypted_content_nonce` | `string` | Per-message nonce used in encryption |

**Encryption scheme:** NIP-44 (XChaCha20-Poly1305 with HKDF-derived shared secret from sender + recipient Nostr keys)

**New service: `Nip44Service`**

```ruby
# app/services/nip44_service.rb
class Nip44Service
  # Encrypt plaintext using sender + recipient Nostr keys
  def encrypt(plaintext, sender_privkey, recipient_pubkey)
    # 1. Derive shared secret via ECDH (secp256k1)
    # 2. Derive encryption key via HKDF
    # 3. Generate random nonce
    # 4. Encrypt with XChaCha20-Poly1305
    # 5. Return { ciphertext:, nonce: }
  end

  # Decrypt ciphertext using recipient's private key + sender's pubkey
  def decrypt(ciphertext, nonce, recipient_privkey, sender_pubkey)
    # 1. Derive shared secret via ECDH
    # 2. Derive decryption key via HKDF
    # 3. Decrypt with XChaCha20-Poly1305
    # 4. Return plaintext
  end
end
```

**Key design decision:** Encryption happens in the **Stimulus controller (client-side JS)**, not server-side. The server should never see plaintext for E2EE DMs. The `Nip44Service` Ruby class is for verification and tooling only — the primary encryption path uses `nostr-tools` npm package which implements NIP-44 natively.

**For encrypted messages:**
- `content` column stores `nil` (or a placeholder like `"[encrypted]"`)
- `encrypted_content` column stores the NIP-44 ciphertext
- `encrypted_content_nonce` stores the per-message nonce

**Fallback:** Unencrypted DMs remain functional for conversations where one party's client doesn't support NIP-44. Encryption is opt-in per conversation until all clients support it.

**E2EE vs. Content Safety trade-off:** E2EE DMs are encrypted client-side, so server-side CSAM scanning (Section 1.5) cannot inspect them. This is an inherent trade-off — the provider cannot scan what it cannot see. This is a well-understood limitation shared by Signal, WhatsApp, and other E2EE messaging systems. Compliance note: legal obligations apply to content the provider has knowledge of; E2EE messages are opaque to the server.

**Flow: E2EE DM**

```
Sender composes DM in Stimulus controller
        │
        ▼
Client-side: nostr-tools NIP-44 encrypt(plaintext, senderPrivkey, recipientPubkey)
        │
        ├── ECDH shared secret derivation
        │
        ├── HKDF key derivation
        │
        ├── XChaCha20-Poly1305 encryption
        │
        ▼
POST /messages with { encrypted_content: ciphertext, encrypted_content_nonce: nonce, content: nil }
        │
        ▼
Server stores ciphertext — never sees plaintext
        │
        ▼
Recipient's client fetches message
        │
        ▼
Client-side: nostr-tools NIP-44 decrypt(ciphertext, nonce, recipientPrivkey, senderPubkey)
        │
        ├── ECDH shared secret derivation
        │
        ├── HKDF key derivation
        │
        ├── XChaCha20-Poly1305 decryption
        │
        ▼
Plaintext displayed to recipient
```

---

#### Layer 3: Token & Identity Hardening (reduces attack surface)

**Goal:** Reduce the blast radius and duration of credential compromise, enforce identity verification, and eliminate single points of failure.

##### 3a. Enforce NIP-05 Verification

Make NIP-05 verification mandatory for remote federation authentication.

| Config column | Type | Default | Description |
|--------------|------|---------|-------------|
| `require_nip05_for_federation` | `boolean` | `true` | Block remote auth if NIP-05 cannot be verified |

When enabled: `NostrAuthController` returns 403 instead of logging-and-continuing when NIP-05 verification fails for a remote user.

##### 3b. Shorter Token TTL + Silent Refresh

Reduce `FederationTokenService::TOKEN_EXPIRY` from 30 days to 24 hours.

| Config column | Type | Default | Description |
|--------------|------|---------|-------------|
| `federation_token_ttl_hours` | `integer` | `24` | Token validity period in hours |

**New service: `FederationTokenRefreshService`**

```ruby
# app/services/federation_token_refresh_service.rb
class FederationTokenRefreshService
  # Client detects 401 → requests new token via home instance
  def refresh(expired_token)
    # 1. Verify the expired token was legitimately issued (check signature, ignore expiry)
    # 2. Check user still exists and is not suspended
    # 3. Check token digest is not in revocation table
    # 4. Issue new token with current TTL
  end
end
```

**Flow: Token Refresh**

```
Client makes federation request
        │
        ▼
Remote instance verifies token → expired (401)
        │
        ▼
Client detects 401 response
        │
        ▼
Client requests new token from home instance
        │
        ├── FederationTokenRefreshService.refresh(expired_token)
        │
        ├── Verify token was legitimately issued (signature valid, ignore expiry)
        │
        ├── Check user is not suspended
        │
        ├── Check token digest not in revoked_federation_tokens
        │
        ├── Issue new token (24h TTL)
        │
        ▼
Client retries original request with new token
```

**Silent refresh:** No user interaction required. The client (Stimulus controller / fetch wrapper) automatically detects 401 and requests a new token from the home instance.

##### 3c. Token Revocation

**New table: `revoked_federation_tokens`**

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `token_digest` | `string` | SHA-256 digest of the revoked token |
| `revoked_at` | `datetime` | When the token was revoked |
| `reason` | `string` | `user_suspended`, `manual_admin`, `instance_blocked`, `security_incident` |
| `created_at` | `datetime` | |

**Indexes:**
- `(token_digest)` unique — fast lookup on every verify call
- `(revoked_at)` — prune old entries

**New model: `RevokedFederationToken`**

Modified `FederationTokenService#verify`: check `RevokedFederationToken.exists?(token_digest:)` before accepting any token.

##### 3d. Token Scoping

Add `scope` field to token payload:

| Scope | Permissions |
|-------|------------|
| `full` | All federation endpoints (Tier 1 instances) |
| `messaging` | Message delivery, conversation references, friend requests |
| `profile_read` | Profile sync and membership queries only (Tier 3 instances) |

Scope is embedded in the signed token payload and verified on each request. `TrustGated` concern checks scope against the requested endpoint.

##### 3e. Conversation Reference Signing

Require a signed Nostr event wrapping conversation reference pushes. The receiving instance verifies the signature before accepting the reference.

Modified flow in `push_conversation_reference`: in addition to checking the blocklist, verify that the push payload includes a valid Nostr event signature from the sending user.

##### 3f. Per-User Key Derivation

Derive per-user encryption keys from `secret_key_base + user_id` instead of bare `secret_key_base`.

```ruby
# Modified: app/models/concerns/has_nostr_identity.rb
def encryption_key
  # OLD: Rails.application.credentials.secret_key_base
  # NEW: HKDF(secret_key_base, salt: "nostr-key-#{id}", info: "nostr-private-key-encryption")
  ActiveSupport::KeyGenerator.new(
    Rails.application.credentials.secret_key_base
  ).generate_key("nostr-key-#{id}", 32)
end
```

**Backwards-compatible migration:** On next access, decrypt with old method (bare `secret_key_base`), re-encrypt with new per-user derived key. No bulk re-encryption migration needed.

### Summary of Changes

#### New database table (1)

| Table | Purpose |
|-------|---------|
| `revoked_federation_tokens` | Track revoked federation tokens for immediate invalidation |

#### Modified existing tables

| Table | Column(s) Added | Purpose |
|-------|----------------|---------|
| `messages` | `nostr_event_id` (string), `signature` (string), `encrypted_content` (text), `encrypted_content_nonce` (string) | Message signing + E2EE DMs |
| `instance_configs` | `require_nip05_for_federation` (boolean, default true), `federation_token_ttl_hours` (integer, default 24) | Token & identity hardening config |

#### New models (1)

| Model | Purpose |
|-------|---------|
| `RevokedFederationToken` | Check token revocation on every verify call |

#### New services (3)

| Service | Purpose |
|---------|---------|
| `MessageSigningService` | Sign messages on create, verify signatures on display |
| `Nip44Service` | NIP-44 encrypt/decrypt for E2EE DMs (Ruby-side tooling) |
| `FederationTokenRefreshService` | Silent token refresh with revocation check |

#### Modified existing services

| Service | Change |
|---------|--------|
| `FederationTokenService` | Reduce TTL to configurable hours, check revocation table, add scope to payload |
| `NostrEventService` | Add message signing (kind 1 events) for message integrity |

#### Modified existing concerns

| Concern | Change |
|---------|--------|
| `HasNostrIdentity` | Per-user key derivation via HKDF instead of bare `secret_key_base` |

### Key Design Decisions

1. **Sign ALL messages, not just federated ones.** A universal integrity guarantee is simpler to reason about and implement. Every message is verifiable regardless of whether the recipient is local or remote.

2. **Client-side encryption for E2EE.** The server never sees plaintext for encrypted DMs — true zero-knowledge. The `nostr-tools` npm package provides NIP-44 natively, so no new JS dependencies are needed.

3. **Gradual E2EE rollout.** Unencrypted DMs remain functional. Encryption is opt-in per conversation until all clients support NIP-44. This avoids a flag day and lets the feature ship incrementally.

4. **E2EE vs. content scanning trade-off is explicit.** Server-side CSAM scanning cannot inspect E2EE messages. This limitation is inherent to E2EE and shared by all major encrypted messaging platforms. It is documented rather than worked around.

5. **Silent token refresh.** 24-hour tokens with automatic refresh provide the security of short-lived credentials with the UX of long-lived ones. No user interaction required.

6. **Per-user key derivation is backwards-compatible.** Existing keys are re-encrypted on next access — no migration job needed. The system gracefully handles both old-format and new-format encrypted keys during the transition.

---

## 2. Trust / Reputation Tier System

### Purpose

Classify instances and users into trust tiers that control rate limits, API access, federation privileges, and feature availability. Tiers range from blocked (Tier 0) to verified (Tier 1).

### Tier Definitions

| Tier  | Name        | Instance Meaning                                               | User Meaning                                          |
| ----- | ----------- | -------------------------------------------------------------- | ----------------------------------------------------- |
| **0** | Blocklisted | Domain-blocked, all communication rejected                     | Pubkey-banned across instance                         |
| **3** | Untrusted   | Unknown instance, first contact, no history                    | New remote user, no verification                      |
| **2** | Standard    | Known instance, established history, no violations             | Authenticated user with valid NIP-05                  |
| **1** | Verified    | Instance has agreed to federation ToS and/or paid verification | User has completed Stripe or Zap payment verification |

### Database Schema

#### `instance_trust_tiers`

One row per known remote instance.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `domain` | `string` | Remote instance domain (unique) |
| `tier` | `integer` | `0`, `1`, `2`, `3` — default `3` |
| `tier_reason` | `string` | Why this tier was assigned: `auto`, `admin_override`, `payment_verified`, `tos_signed` |
| `tos_accepted_at` | `datetime` | When the remote instance accepted federation ToS |
| `tos_version` | `string` | Version of ToS accepted (e.g. `"1.0"`) |
| `first_seen_at` | `datetime` | First federation interaction |
| `last_seen_at` | `datetime` | Most recent federation interaction |
| `auth_success_count` | `integer` | Lifetime successful auths from this domain |
| `auth_failure_count` | `integer` | Lifetime failed auths |
| `report_count` | `integer` | Moderation reports involving users from this domain |
| `metadata` | `jsonb` | Admin notes, Stripe customer ID, etc. |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(domain)` unique
- `(tier)`
- `(last_seen_at)`

#### `user_trust_tiers`

One row per user (local or remote).

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `user_id` | `bigint` | FK → `users` (nullable — for pubkey-only records) |
| `nostr_public_key` | `string` | The user's pubkey (always present) |
| `tier` | `integer` | `0`, `1`, `2`, `3` — default `3` for remote, `2` for local |
| `tier_reason` | `string` | `auto`, `admin_override`, `payment_verified`, `nip05_verified` |
| `verification_method` | `string` | `stripe`, `zap`, `admin`, `nip05` — how they reached their tier |
| `verified_at` | `datetime` | When verification completed |
| `report_count` | `integer` | Moderation reports against this user |
| `metadata` | `jsonb` | Stripe customer ID, Lightning payment hash, admin notes |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(user_id)` unique where not null
- `(nostr_public_key)` unique
- `(tier)`

#### `federation_tos_versions`

Stores versions of the federation Terms of Service.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `version` | `string` | Semver string (e.g. `"1.0"`) |
| `content` | `text` | Full ToS text (Markdown) |
| `published_at` | `datetime` | When this version became active |
| `created_at` | `datetime` | |

**Indexes:**
- `(version)` unique

### New Models

| Model | File | Purpose |
|-------|------|---------|
| `InstanceTrustTier` | `app/models/instance_trust_tier.rb` | Tier lookup with scopes: `blocklisted`, `untrusted`, `standard`, `verified`. Methods: `promote!`, `demote!`, `auto_evaluate!`. |
| `UserTrustTier` | `app/models/user_trust_tier.rb` | User tier lookup. `tier_for(user_or_pubkey)` class method. `verified?`, `blocklisted?` predicates. |
| `FederationTosVersion` | `app/models/federation_tos_version.rb` | ToS content storage. `current` class method returns latest version. |

### New Services

| Service | File | Purpose |
|---------|------|---------|
| `TrustEvaluationService` | `app/services/trust_evaluation_service.rb` | Auto-evaluates tier based on history: auth success/failure ratio, report count, age. Called periodically and on significant events. |
| `FederationTosService` | `app/services/federation_tos_service.rb` | Serves ToS to remote instances, records acceptance, validates version currency. |

### New Controllers

| Controller | File | Routes | Purpose |
|------------|------|--------|---------|
| `Admin::TrustTiersController` | `app/controllers/admin/trust_tiers_controller.rb` | `GET /admin/trust_tiers`, `PATCH /admin/trust_tiers/:id` | View and override instance/user tiers |
| `Federation::TosController` | `app/controllers/federation/tos_controller.rb` | `GET /federation/tos`, `POST /federation/tos/accept` | Serve ToS, record acceptance from remote instances |

### New Concern

| Concern | File | Purpose |
|---------|------|---------|
| `TrustGated` | `app/controllers/concerns/trust_gated.rb` | `before_action` that checks instance/user tier. Rejects requests from Tier 0. Adds tier info to `request.env` for downstream use. |

### Modified Existing Files

| File | Change |
|------|--------|
| `app/models/instance_blocklist.rb` | On create: also set `InstanceTrustTier` to tier 0 for that domain. On destroy: reset to tier 3. |
| `app/controllers/nostr/auth_controller.rb` | Include `TrustGated`. Reject auth from tier 0 domains. Increment `auth_success_count` / `auth_failure_count`. |
| `app/controllers/federation/profiles_controller.rb` | Include `TrustGated`. Gate profile access by tier. |
| `config/routes.rb` | Add admin trust tier routes and federation ToS routes. |

### Flow: Automatic Tier Evaluation

```
Remote instance "new.chat" sends first auth request
        │
        ▼
TrustGated concern checks InstanceTrustTier.find_or_create_by(domain:)
        │
        ├── No record exists → creates with tier=3 (untrusted), first_seen_at=now
        │
        ▼
Auth proceeds normally (tier 3 is allowed, just rate-limited more)
        │
        ▼
On auth success: increment auth_success_count, update last_seen_at
        │
        ▼
TrustEvaluationService.auto_evaluate!(instance_trust_tier)
        │
        ├── auth_success_count > 10 AND age > 7 days AND report_count == 0
        │       → promote to tier 2 (standard)
        │
        ├── report_count > 5 OR auth_failure_ratio > 50%
        │       → demote to tier 3 or flag for admin review
        │
        └── tos_accepted? AND (payment_verified? OR admin_approved?)
                → promote to tier 1 (verified)
```

### Flow: Federation Terms of Service

```
Instance admin on remote.chat wants Tier 1
        │
        ▼
GET /federation/tos → returns current ToS version + content
        │
        ▼
Remote admin reviews ToS
        │
        ▼
POST /federation/tos/accept
  { domain: "remote.chat", version: "1.0", signed_event: <NIP-42 signed> }
        │
        ▼
FederationTosService verifies:
  1. Signature is valid (proves domain ownership via NIP-05)
  2. Version matches current ToS
        │
        ▼
InstanceTrustTier.update!(tos_accepted_at: now, tos_version: "1.0")
        │
        ▼
If payment also verified → auto-promote to Tier 1
```

### Verified User Benefits (Tier 1 Perks)

Instance owners configure which perks Tier 1 (verified) users receive. This gives users a tangible reason to verify and gives instance owners a monetization lever — they choose what to gate behind verification.

#### `verified_user_benefits`

Singleton config (like `InstanceConfig`) — one row defines all benefit settings.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `max_servers_per_user` | `integer` | Override for verified users (0 = use instance default) |
| `max_upload_size_mb` | `integer` | Override upload limit (0 = use instance default) |
| `max_storage_per_user_mb` | `integer` | Override storage limit (0 = use instance default) |
| `max_emojis_per_server` | `integer` | Override server emoji limit for servers owned by verified users (0 = use instance default) |
| `max_stickers_per_server` | `integer` | Override server sticker limit for servers owned by verified users (0 = use instance default) |
| `custom_themes_enabled` | `boolean` | Can use/create custom themes (default `false`) |
| `animated_avatar_enabled` | `boolean` | Can use animated GIF avatars (default `false`) |
| `animated_banner_enabled` | `boolean` | Can use animated GIF banners (default `false`) |
| `custom_profile_badges` | `boolean` | Gets a "Verified" badge on profile (default `true`) |
| `extended_bio_length` | `integer` | Max bio characters for verified (0 = use default) |
| `priority_support` | `boolean` | Flagged for priority in moderation queue (default `false`) |
| `higher_rate_limits` | `boolean` | Uses tier 1 rate limits from Section 3 (default `true`) |
| `custom_status_emoji` | `boolean` | Can use any emoji in status, not just preset (default `false`) |
| `gif_collections_limit` | `integer` | Override max GIF collections (0 = use default) |
| `screen_share_hd` | `boolean` | HD screen sharing in voice channels (default `false`) |
| `voice_priority_speaker` | `boolean` | Priority speaker in voice channels (default `false`) |
| `gated_servers_enabled` | `boolean` | Server owners can require verification to join (default `false`) |
| `gated_channels_enabled` | `boolean` | Server owners can require verification to access specific channels (default `false`) |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

#### `custom_themes`

User-created themes (colors, fonts, CSS overrides within a safe sandbox).

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `user_id` | `bigint` | FK → `users` (creator) |
| `name` | `string(50)` | Theme name |
| `theme_data` | `jsonb` | Color palette, font choices, CSS variable overrides |
| `public` | `boolean` | Whether other verified users can use this theme (default `false`) |
| `public_id` | `string(12)` | Public-facing ID |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(user_id, name)` unique
- `(public_id)` unique
- `(public)` — for browsing shared themes

**`theme_data` structure:**

```json
{
  "primary_color": "#5865F2",
  "secondary_color": "#4752C4",
  "background_color": "#36393f",
  "sidebar_color": "#2f3136",
  "text_color": "#dcddde",
  "accent_color": "#00b0f4",
  "font_family": "default",
  "message_density": "default",
  "border_radius": "default"
}
```

#### New Models

| Model | File | Purpose |
|-------|------|---------|
| `VerifiedUserBenefit` | `app/models/verified_user_benefit.rb` | Singleton config. `self.current` returns the single row. Methods: `perk_enabled?(perk_name)`, `limit_for(setting)` — returns the override or falls back to `InstanceConfig` default. |
| `CustomTheme` | `app/models/custom_theme.rb` | Belongs to user. Validates `theme_data` keys against allowlist. Scope: `shared` for browsable themes. |

#### New Service

| Service | File | Purpose |
|---------|------|---------|
| `UserBenefitsService` | `app/services/user_benefits_service.rb` | Central query point: `UserBenefitsService.limit_for(user, :max_servers_per_user)` returns the verified override if user is tier 1, otherwise the `InstanceConfig` default. `UserBenefitsService.can?(user, :custom_themes)` returns boolean. `UserBenefitsService.server_limit_for(server_owner, :max_emojis_per_server)` returns verified override if the server owner is tier 1. |

#### New Controllers

| Controller | File | Routes | Purpose |
|------------|------|--------|---------|
| `CustomThemesController` | `app/controllers/custom_themes_controller.rb` | `GET/POST/PATCH/DELETE /custom_themes`, `GET /custom_themes/browse` | CRUD + browse shared themes (gated by tier + perk) |
| `Admin::VerifiedBenefitsController` | `app/controllers/admin/verified_benefits_controller.rb` | `GET/PATCH /admin/verified_benefits` | Admin UI to toggle which perks are active and set override limits |

#### New Concern

| Concern | File | Purpose |
|---------|------|---------|
| `BenefitGated` | `app/controllers/concerns/benefit_gated.rb` | `before_action` that checks `UserBenefitsService.can?(current_user, perk)`. Returns 403 with "This feature requires verification" if user is not tier 1 or the perk is disabled. Also used on servers/channels with `requires_verification` to gate access. |

#### Modified Existing Files

| File | Change |
|------|--------|
| `app/models/instance_config.rb` | `server_limit_reached_for?(user)` now delegates to `UserBenefitsService.limit_for(user, :max_servers_per_user)` instead of reading `max_servers_per_user` directly. Same for upload size and storage checks. |
| `app/models/server.rb` | Add `requires_verification` boolean column. When true, only tier 1 users can join (checked in `InvitesController#accept` and `ServersController#join`). Emoji/sticker limits on the server use `UserBenefitsService.server_limit_for(server.owner, :max_emojis_per_server)`. |
| `app/models/channel.rb` | Add `requires_verification` boolean column. When true, only tier 1 members can view/post in the channel (checked via `BenefitGated` concern + channel permission logic). |
| `app/models/user.rb` | Add `has_many :custom_themes`. Add `verified?` convenience method that checks `UserTrustTier`. |
| `app/controllers/settings_controller.rb` | Show verification badge status, link to `/payments/verify` if not tier 1. |
| `app/controllers/server_settings_controller.rb` | Add "Require verification to join" toggle in server settings. |
| `app/controllers/channels_controller.rb` | Add "Require verification" toggle in channel settings. Check `requires_verification` before granting access. |
| `app/controllers/server_emojis_controller.rb` | Use `UserBenefitsService.server_limit_for` for the emoji cap instead of a hardcoded or missing limit. |
| `app/controllers/server_stickers_controller.rb` | Same — use `UserBenefitsService.server_limit_for` for the sticker cap. |
| `app/views/` (profile cards, member lists) | Show verified badge next to username when `custom_profile_badges` is enabled and user is tier 1. |
| `config/routes.rb` | Add custom theme routes and admin verified benefits routes. |
| `app/javascript/controllers/` | Theme application — load `CustomTheme.theme_data` CSS variables into `:root` when a user has an active theme selected. |

#### Flow: Instance Owner Configures Benefits

```
Admin visits /admin/verified_benefits
        │
        ▼
Sees toggle switches and limit overrides for each perk:

  Limits (verified server owners get higher caps):
    [x] Max servers/user = 10          (instance default: 5)
    [x] Max upload size = 50MB         (instance default: 25MB)
    [x] Max emojis/server = 200        (instance default: 50)
    [x] Max stickers/server = 100      (instance default: 30)

  Features:
    [x] Verified badge on profile
    [x] Higher rate limits
    [ ] Custom themes                   → toggles on
    [ ] Animated avatars
    [ ] HD screen share
    [ ] Gated servers (owners can require verification to join)  → toggles on
    [ ] Gated channels (owners can require verification to view) → toggles on
        │
        ▼
VerifiedUserBenefit.current.update!(gated_servers_enabled: true, ...)
```

#### Flow: Limit Enforcement

```
User tries to create a 6th server
        │
        ▼
InstanceConfig.current.server_limit_reached_for?(user)
        │
        ▼
UserBenefitsService.limit_for(user, :max_servers_per_user)
        │
        ├── User is Tier 1 AND VerifiedUserBenefit.current.max_servers_per_user > 0?
        │       → return 10 (verified override)
        │
        └── Otherwise
                → return 5 (InstanceConfig default)
        │
        ▼
user.owned_servers.count (5) < 10 → allowed!
```

#### Flow: Gated Server (Verification Required to Join)

```
Server owner (verified) enables "Require verification" in server settings
        │
        ▼
server.update!(requires_verification: true)
  (only allowed if gated_servers_enabled in VerifiedUserBenefit)
        │
        ▼
Non-verified user tries to join via invite
        │
        ▼
InvitesController#accept / ServersController#join
        │
        ├── server.requires_verification? AND !user.verified?
        │       → reject with "This server requires verified members"
        │         show link to /payments/verify
        │
        └── user.verified? OR !server.requires_verification?
                → join normally
```

#### Flow: Gated Channel (Verification Required to Access)

```
Server admin enables "Require verification" on a channel
        │
        ▼
channel.update!(requires_verification: true)
  (only allowed if gated_channels_enabled in VerifiedUserBenefit)
        │
        ▼
Non-verified member tries to view channel
        │
        ▼
Channel permission check (existing system)
        │
        ├── channel.requires_verification? AND !user.verified?
        │       → channel hidden from sidebar / shows lock icon
        │         clicking shows "Verify to unlock this channel"
        │
        └── user.verified? OR !channel.requires_verification?
                → normal access per existing role permissions
```

#### Flow: Verified Badge Display

```
Profile card / member list renders username
        │
        ▼
Check: user.verified? AND VerifiedUserBenefit.current.custom_profile_badges?
        │
        ├── true → render ✓ badge SVG next to username
        └── false → render normally
```

---

## 3. Rate Limiting by Tier

### Purpose

Dynamic rate limiting where trust tier determines the limits. Untrusted instances get restrictive limits; verified instances get generous ones.

### Configuration Schema

Rate limits are stored in `InstanceConfig` as a new JSONB column, allowing admin customization without code deploys.

#### Add to `instance_configs`

| Column | Type | Description |
|--------|------|-------------|
| `rate_limits` | `jsonb` | Per-tier rate limit configuration |

**Default value:**

```json
{
  "tier_3": {
    "auth_per_minute": 5,
    "auth_per_hour": 30,
    "api_per_minute": 30,
    "api_per_hour": 500,
    "federation_per_minute": 10,
    "federation_per_hour": 200
  },
  "tier_2": {
    "auth_per_minute": 15,
    "auth_per_hour": 100,
    "api_per_minute": 120,
    "api_per_hour": 5000,
    "federation_per_minute": 60,
    "federation_per_hour": 2000
  },
  "tier_1": {
    "auth_per_minute": 30,
    "auth_per_hour": 300,
    "api_per_minute": 300,
    "api_per_hour": 20000,
    "federation_per_minute": 200,
    "federation_per_hour": 10000
  }
}
```

### Implementation: Dynamic Rack::Attack

#### New File: `app/services/rate_limit_service.rb`

Reads tier for a request and returns the applicable limits.

```ruby
class RateLimitService
  def self.limits_for(request)
    domain = extract_domain(request)
    tier = InstanceTrustTier.find_by(domain: domain)&.tier || 3
    config = InstanceConfig.current.rate_limits || default_limits
    config["tier_#{tier}"] || config["tier_3"]
  end

  def self.extract_domain(request)
    # From X-Federation-Token header, requesting_instance param, or reverse DNS
    request.params["requesting_instance"] ||
      request.env["HTTP_X_REQUESTING_INSTANCE"] ||
      request.ip
  end
end
```

### Modified File: `config/initializers/rack_attack.rb`

Replace static limits with dynamic tier-aware throttles.

```ruby
class Rack::Attack
  ### --- Tier-Aware Federation Rate Limiting ---

  # Throttle federation API per instance domain
  throttle("federation/domain", limit: proc { |req|
    RateLimitService.limits_for(req)["federation_per_minute"] || 10
  }, period: 1.minute) do |req|
    RateLimitService.extract_domain(req) if req.path.start_with?("/federation")
  end

  # Throttle auth per instance domain
  throttle("nostr_auth/domain/dynamic", limit: proc { |req|
    RateLimitService.limits_for(req)["auth_per_minute"] || 5
  }, period: 1.minute) do |req|
    RateLimitService.extract_domain(req) if req.path.start_with?("/auth/nostr")
  end

  # Per-user API rate limiting (for authenticated requests)
  throttle("api/user", limit: proc { |req|
    user_tier = req.env["trust.user_tier"] || 3
    config = InstanceConfig.current.rate_limits || {}
    (config["tier_#{user_tier}"] || {})["api_per_minute"] || 30
  }, period: 1.minute) do |req|
    req.env["warden"]&.user&.id if req.path.start_with?("/api")
  end

  ### --- Existing static limits (kept for non-federation endpoints) ---

  throttle("login/ip", limit: 5, period: 20.seconds) do |req|
    req.ip if req.path == "/users/sign_in" && req.post?
  end

  throttle("registration/ip", limit: 3, period: 1.hour) do |req|
    req.ip if req.path == "/users" && req.post?
  end

  ### --- Rate Limit Headers ---

  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"] || {}
    now = match_data[:epoch_time] || Time.now.to_i
    retry_after = match_data[:period] ? (match_data[:period] - (now % match_data[:period])) : 60

    headers = {
      "Content-Type" => "application/json",
      "Retry-After" => retry_after.to_s,
      "X-RateLimit-Limit" => match_data[:limit].to_s,
      "X-RateLimit-Remaining" => "0",
      "X-RateLimit-Reset" => (now + retry_after).to_s
    }

    [429, headers, [{ error: "Rate limit exceeded. Retry after #{retry_after} seconds." }.to_json]]
  end
end
```

### New Middleware: `app/middleware/trust_tier_middleware.rb`

Injects tier info into the Rack env for downstream use.

```ruby
class TrustTierMiddleware
  def initialize(app)
    @app = app
  end

  def call(env)
    request = Rack::Request.new(env)
    domain = RateLimitService.extract_domain(request)

    if domain.present?
      tier_record = InstanceTrustTier.find_by(domain: domain)
      env["trust.instance_tier"] = tier_record&.tier || 3
      env["trust.instance_domain"] = domain
    end

    @app.call(env)
  end
end
```

### Rate Limit Response Headers (on all responses)

#### New Concern: `RateLimitHeaders`

| Concern | File | Purpose |
|---------|------|---------|
| `RateLimitHeaders` | `app/controllers/concerns/rate_limit_headers.rb` | `after_action` that sets `X-RateLimit-*` headers on every response for federation endpoints. |

### Modified Existing Files

| File | Change |
|------|--------|
| `config/initializers/rack_attack.rb` | Replace static throttles with dynamic tier-aware ones (see above) |
| `config/application.rb` | Register `TrustTierMiddleware` |
| `app/models/instance_config.rb` | Add `rate_limits` attribute, `rate_limits_for_tier(tier)` method |
| `app/controllers/application_controller.rb` | Include `RateLimitHeaders` concern |

---

## 4. API Versioning

### Purpose

Version the federation API so instances running different versions can negotiate compatibility. Legacy routes remain functional with deprecation headers.

### URL Structure

```
/api/v1/federation/*    ← new versioned routes
/federation/*           ← legacy (maps to v1, adds deprecation headers)
```

### Route Changes

#### New versioned routes in `config/routes.rb`

```ruby
namespace :api do
  namespace :v1 do
    namespace :federation do
      post :create_server, to: "servers#create"
      get "profiles/:pubkey", to: "profiles#show"
      get "profiles/:pubkey/servers", to: "profiles#servers"
      get "profiles/:pubkey/conversations", to: "profiles#conversations"
      get "profiles/:pubkey/friends", to: "profiles#friends"
      get "profiles/:pubkey/folders", to: "profiles#folders"
      get "profiles/:pubkey/gif_collections", to: "profiles#gif_collections"
      get "profiles/:pubkey/memberships", to: "profiles#memberships"
      post "profiles/:pubkey/report_memberships", to: "profiles#report_memberships"
      get "syncing", to: "syncing#show"

      post "users/lookup", to: "friend_requests#lookup"
      post "friend_requests", to: "friend_requests#create"
      post "friend_requests/respond", to: "friend_requests#respond"
      post "conversations/push_reference", to: "friend_requests#push_conversation_reference"

      # New in v1
      get "tos", to: "tos#show"
      post "tos/accept", to: "tos#accept"
      get "trust", to: "trust#show"
    end
  end
end

# Legacy routes — kept for backward compatibility
namespace :federation do
  # ... existing routes unchanged, but controller adds deprecation headers
end
```

### New Concern: `ApiVersioning`

```ruby
# app/controllers/concerns/api_versioning.rb
module ApiVersioning
  extend ActiveSupport::Concern

  included do
    before_action :set_api_version
    after_action :add_version_headers
  end

  private

  def set_api_version
    @api_version = extract_version
  end

  def extract_version
    # From URL path
    if request.path.match?(%r{/api/v(\d+)/})
      request.path.match(%r{/api/v(\d+)/})[1].to_i
    # From Accept header: application/vnd.inferno.v1+json
    elsif request.headers["Accept"]&.match?(/vnd\.inferno\.v(\d+)/)
      request.headers["Accept"].match(/vnd\.inferno\.v(\d+)/)[1].to_i
    else
      1 # default
    end
  end

  def add_version_headers
    response.headers["X-API-Version"] = @api_version.to_s
    response.headers["X-API-Latest-Version"] = "1"

    # Deprecation header for legacy routes
    if request.path.start_with?("/federation") && !request.path.start_with?("/api/")
      response.headers["Deprecation"] = "true"
      response.headers["Sunset"] = 6.months.from_now.httpdate
      response.headers["Link"] = "</api/v1#{request.path}>; rel=\"successor-version\""
    end
  end
end
```

### Version Negotiation

Remote instances include their supported version in the request:

```
GET /api/v1/federation/profiles/abc123
Accept: application/vnd.inferno.v1+json
X-Federation-Client-Version: 1
```

The server responds with its version info:

```
X-API-Version: 1
X-API-Latest-Version: 1
X-API-Min-Supported-Version: 1
```

### New Controllers (v1 namespace)

| Controller | File | Purpose |
|------------|------|---------|
| `Api::V1::Federation::ProfilesController` | `app/controllers/api/v1/federation/profiles_controller.rb` | Versioned profiles endpoint (delegates to existing logic) |
| `Api::V1::Federation::ServersController` | `app/controllers/api/v1/federation/servers_controller.rb` | Versioned server creation |
| `Api::V1::Federation::FriendRequestsController` | `app/controllers/api/v1/federation/friend_requests_controller.rb` | Versioned friend requests |
| `Api::V1::Federation::TosController` | `app/controllers/api/v1/federation/tos_controller.rb` | ToS serving and acceptance |
| `Api::V1::Federation::TrustController` | `app/controllers/api/v1/federation/trust_controller.rb` | Tier info endpoint |
| `Api::V1::Federation::SyncingController` | `app/controllers/api/v1/federation/syncing_controller.rb` | Versioned syncing |

### New Base Controller

| Controller | File | Purpose |
|------------|------|---------|
| `Api::V1::Federation::BaseController` | `app/controllers/api/v1/federation/base_controller.rb` | Shared concerns: `ApiVersioning`, `TrustGated`, `RateLimitHeaders`. JSON-only responses. |

### Modified Existing Files

| File | Change |
|------|--------|
| `app/controllers/federation/profiles_controller.rb` | Include `ApiVersioning` concern to add deprecation headers on legacy routes |
| `app/controllers/federation/servers_controller.rb` | Include `ApiVersioning` concern |
| `app/controllers/federation/friend_requests_controller.rb` | Include `ApiVersioning` concern |
| `app/services/federation_service.rb` | Add `api_version` parameter to HTTP methods. Default to v1 path (`/api/v1/federation/...`). Fall back to legacy path if v1 returns 404. |
| `config/routes.rb` | Add `api/v1/federation` namespace routes alongside existing `federation` routes |

### Flow: Version Negotiation on Federation Call

```
Instance A (v1) calls Instance B
        │
        ▼
FederationService.fetch_remote_profile(...)
        │
        ├── Try: GET https://B/api/v1/federation/profiles/:pubkey
        │       │
        │       ├── 200 OK → use response, note X-API-Version header
        │       │
        │       └── 404 Not Found → Instance B is pre-versioning
        │               │
        │               ▼
        │           Fallback: GET https://B/federation/profiles/:pubkey
        │               │
        │               └── 200 OK → works, but log that B needs upgrade
        │
        └── Store B's API version in InstanceTrustTier.metadata
```

---

## 5. Monetization (Stripe + Zaps)

### Purpose

Two payment paths for Tier 1 verification: **Stripe** (credit/debit card) for mainstream users, and **Zaps** (Bitcoin Lightning via NIP-57) for crypto-native users. Instance owners earn a configurable fee percentage on payments processed through their instance.

### Database Schema

#### `payment_records`

Unified payment tracking for both Stripe and Zap payments.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `user_id` | `bigint` | FK → `users` (the payer) |
| `payment_type` | `string` | `stripe`, `zap` |
| `payment_purpose` | `string` | `tier1_verification`, `instance_subscription`, `donation` |
| `amount_sats` | `bigint` | Amount in satoshis (canonical unit — Stripe amounts converted) |
| `amount_fiat` | `decimal(10,2)` | Fiat amount (for Stripe payments) |
| `fiat_currency` | `string` | `USD`, `EUR`, etc. |
| `status` | `string` | `pending`, `completed`, `failed`, `refunded`, `expired` |
| `stripe_payment_intent_id` | `string` | Stripe PaymentIntent ID (nullable) |
| `stripe_customer_id` | `string` | Stripe Customer ID (nullable) |
| `lightning_invoice` | `text` | BOLT11 invoice string (nullable) |
| `lightning_payment_hash` | `string` | Lightning payment hash (nullable) |
| `lightning_preimage` | `string` | Lightning payment preimage / proof (nullable) |
| `nostr_zap_receipt_id` | `string` | NIP-57 zap receipt event ID (nullable) |
| `instance_fee_sats` | `bigint` | Instance owner's fee portion |
| `instance_fee_fiat` | `decimal(10,2)` | Instance owner's fee in fiat |
| `metadata` | `jsonb` | Extra context (exchange rate used, etc.) |
| `completed_at` | `datetime` | When payment was confirmed |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(user_id, payment_purpose)`
- `(stripe_payment_intent_id)` unique where not null
- `(lightning_payment_hash)` unique where not null
- `(nostr_zap_receipt_id)` unique where not null
- `(status, created_at)`

#### `instance_payment_configs`

Instance-level payment settings (extends the singleton `InstanceConfig` pattern).

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `stripe_enabled` | `boolean` | Whether Stripe payments are active |
| `stripe_publishable_key` | `string` | Stripe public key |
| `stripe_secret_key_encrypted` | `text` | Encrypted Stripe secret key |
| `stripe_webhook_secret_encrypted` | `text` | Encrypted webhook signing secret |
| `zaps_enabled` | `boolean` | Whether Lightning Zap payments are active |
| `lightning_address` | `string` | Instance owner's Lightning address (e.g. `admin@getalby.com`) |
| `lightning_lnurl` | `string` | LNURL-pay endpoint (alternative to Lightning address) |
| `verification_price_sats` | `bigint` | Price for Tier 1 verification in sats |
| `verification_price_fiat` | `decimal(10,2)` | Price for Tier 1 verification in fiat |
| `verification_fiat_currency` | `string` | Default `USD` |
| `instance_fee_percent` | `decimal(5,2)` | Instance owner's cut (e.g. `10.00` = 10%) |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Note:** This is a singleton like `InstanceConfig` — only one row exists.

**Indexes:** none needed (singleton)

#### `stripe_customers`

Maps users to Stripe customer records for recurring interactions.

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `user_id` | `bigint` | FK → `users` |
| `stripe_customer_id` | `string` | Stripe Customer ID |
| `default_payment_method` | `string` | Stripe PaymentMethod ID |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(user_id)` unique
- `(stripe_customer_id)` unique

### New Models

| Model | File | Purpose |
|-------|------|---------|
| `PaymentRecord` | `app/models/payment_record.rb` | Tracks all payments. Scopes: `completed`, `pending`, `by_type`. Methods: `complete!`, `fail!`, `refund!`. PaperTrail versioned. |
| `InstancePaymentConfig` | `app/models/instance_payment_config.rb` | Singleton pattern like `InstanceConfig`. Encrypts Stripe keys with `ActiveSupport::MessageEncryptor`. Methods: `stripe_configured?`, `zaps_configured?`, `any_payment_enabled?`. |
| `StripeCustomer` | `app/models/stripe_customer.rb` | Maps user → Stripe customer. Created on first Stripe interaction. |

### New Services

| Service | File | Purpose |
|---------|------|---------|
| `StripePaymentService` | `app/services/stripe_payment_service.rb` | Creates PaymentIntent, handles webhook events, confirms payment, updates tier. |
| `ZapPaymentService` | `app/services/zap_payment_service.rb` | Generates Lightning invoice (via LNURL or direct), monitors for payment, verifies NIP-57 zap receipt, updates tier. |
| `VerificationPaymentService` | `app/services/verification_payment_service.rb` | Orchestrator: determines available payment methods, delegates to Stripe or Zap service, handles tier promotion on completion. |
| `InstanceFeeService` | `app/services/instance_fee_service.rb` | Calculates instance owner's fee from a payment. For Stripe: deducted before payout. For Zaps: tracked for manual settlement. |

### New Controllers

| Controller | File | Routes | Purpose |
|------------|------|--------|---------|
| `Payments::StripeController` | `app/controllers/payments/stripe_controller.rb` | `POST /payments/stripe/create_intent`, `POST /payments/stripe/webhooks` | Stripe PaymentIntent creation and webhook handling |
| `Payments::ZapsController` | `app/controllers/payments/zaps_controller.rb` | `POST /payments/zaps/create_invoice`, `GET /payments/zaps/check/:payment_hash`, `POST /payments/zaps/webhook` | Lightning invoice generation and payment verification |
| `Payments::VerificationController` | `app/controllers/payments/verification_controller.rb` | `GET /payments/verify`, `POST /payments/verify` | User-facing verification page showing available payment options |
| `Admin::PaymentConfigController` | `app/controllers/admin/payment_config_controller.rb` | `GET /admin/payment_config`, `PATCH /admin/payment_config` | Admin UI for configuring Stripe keys, Lightning address, prices, fee % |
| `Admin::PaymentRecordsController` | `app/controllers/admin/payment_records_controller.rb` | `GET /admin/payment_records` | Admin view of all payments and revenue |

### New Jobs

| Job | File | Purpose |
|-----|------|---------|
| `CheckLightningPaymentJob` | `app/jobs/check_lightning_payment_job.rb` | Polls Lightning node/LNURL for payment confirmation. Retries with backoff for up to 1 hour. |
| `ExpireUnpaidInvoicesJob` | `app/jobs/expire_unpaid_invoices_job.rb` | Marks `pending` payments older than 1 hour as `expired`. Runs every 15 minutes. |

### Modified Existing Files

| File | Change |
|------|--------|
| `Gemfile` | Add `gem "stripe"` for Stripe API |
| `config/routes.rb` | Add `namespace :payments` routes and admin payment routes |
| `app/models/user_trust_tier.rb` | `after_update :check_verification` — when `verification_method` is set and payment confirmed, promote to tier 1 |
| `config/credentials.yml.enc` | Add `stripe.secret_key`, `stripe.publishable_key`, `stripe.webhook_secret` (alternative to DB-stored keys) |

### Flow: Stripe Verification Payment

```
User clicks "Get Verified" → /payments/verify
        │
        ▼
VerificationPaymentService.available_methods
        │
        ├── Stripe enabled? → show credit card option
        └── Zaps enabled?   → show Lightning option
        │
        ▼
User selects Stripe → clicks "Pay with Card"
        │
        ▼
POST /payments/stripe/create_intent
  { purpose: "tier1_verification" }
        │
        ▼
StripePaymentService.create_intent(user:, amount:, purpose:)
        │
        ├── Find or create StripeCustomer for user
        ├── Create Stripe PaymentIntent via API
        │     amount: verification_price_fiat (e.g. $4.99)
        │     metadata: { user_id:, purpose:, instance_domain: }
        ├── Create PaymentRecord (status: "pending")
        └── Return client_secret to frontend
        │
        ▼
Frontend uses Stripe.js to collect card → confirmCardPayment(client_secret)
        │
        ▼
Stripe sends webhook → POST /payments/stripe/webhooks
        │
        ▼
StripePaymentService.handle_webhook(event)
        │
        ├── payment_intent.succeeded:
        │     ├── PaymentRecord.complete!
        │     ├── InstanceFeeService.calculate(payment_record)
        │     ├── UserTrustTier.find_by(user:).update!(tier: 1, verification_method: "stripe")
        │     └── AuditService.log(event_type: "tier1_verified", ...)
        │
        └── payment_intent.payment_failed:
              └── PaymentRecord.fail!
```

### Flow: Lightning Zap Verification Payment

```
User clicks "Get Verified" → /payments/verify
        │
        ▼
User selects "Pay with Lightning"
        │
        ▼
POST /payments/zaps/create_invoice
  { purpose: "tier1_verification" }
        │
        ▼
ZapPaymentService.create_invoice(user:, amount_sats:, purpose:)
        │
        ├── Build NIP-57 zap request event:
        │     {
        │       kind: 9734,
        │       content: "Tier 1 verification",
        │       tags: [
        │         ["p", <instance_owner_pubkey>],
        │         ["amount", <amount_in_msats>],
        │         ["relays", <relay_urls>],
        │         ["lnurl", <instance_lnurl>]
        │       ]
        │     }
        │
        ├── POST to instance Lightning address LNURL endpoint:
        │     GET <lightning_address>/.well-known/lnurlp/<user>
        │     → returns callback URL
        │     GET <callback>?amount=<msats>&nostr=<zap_request_event>
        │     → returns { pr: "<BOLT11 invoice>" }
        │
        ├── Create PaymentRecord (status: "pending", lightning_invoice: pr)
        │
        └── Return { invoice: "<BOLT11>", payment_hash: "..." } to frontend
        │
        ▼
Frontend displays QR code / "Open in wallet" link
        │
        ▼
User pays invoice in their Lightning wallet
        │
        ▼
Two verification paths (race — first one wins):

  Path A: Webhook from Lightning provider
    POST /payments/zaps/webhook → ZapPaymentService.handle_webhook

  Path B: Poll for NIP-57 zap receipt on relay
    CheckLightningPaymentJob polls for Kind 9735 (zap receipt)
    matching the payment hash
        │
        ▼
ZapPaymentService.confirm_payment(payment_record)
        │
        ├── Verify zap receipt signature (must be from instance's Lightning address)
        ├── PaymentRecord.complete!(lightning_preimage:, nostr_zap_receipt_id:)
        ├── InstanceFeeService.calculate(payment_record)
        ├── UserTrustTier.find_by(user:).update!(tier: 1, verification_method: "zap")
        └── AuditService.log(event_type: "tier1_verified", ...)
        │
        ▼
Frontend polls GET /payments/zaps/check/:payment_hash
  → returns { status: "completed" }
  → frontend shows "Verified!" and refreshes user profile
```

### Instance Owner Revenue

```
Payment of 10,000 sats for verification
        │
        ▼
InstanceFeeService.calculate(payment_record)
        │
        ├── instance_fee_percent = 10%
        ├── instance_fee_sats = 1,000 sats
        ├── payment_record.update!(instance_fee_sats: 1000)
        │
        ├── For Stripe:
        │     Stripe Connect destination charge or manual transfer
        │     Instance owner receives 10% of payment via Stripe
        │
        └── For Zaps:
              Lightning payment goes directly to instance owner's address
              The full amount goes to the owner — the "fee" is 100% by default
              (Instance owner can optionally forward a portion to the app developer
               via a separate Lightning address configured in InstancePaymentConfig)
```

---

## 6. App Updates

### Purpose

Check for new releases of Inferno Chat via the GitHub Releases API and notify instance admins in the dashboard.

### Database Schema

#### Add to `instance_configs`

| Column | Type | Description |
|--------|------|-------------|
| `current_app_version` | `string` | The running version (set at deploy time) |
| `latest_known_version` | `string` | Last version found from GitHub |
| `last_update_check_at` | `datetime` | When the last check ran |
| `update_check_enabled` | `boolean` | Default `true` — admin can disable |
| `github_repo` | `string` | Default `"your-org/inferno-chat"` — configurable for forks |

#### `app_update_notifications`

| Column | Type | Description |
|--------|------|-------------|
| `id` | `bigint` | Primary key |
| `version` | `string` | Release version tag (e.g. `"1.2.0"`) |
| `release_name` | `string` | GitHub release title |
| `release_notes` | `text` | Release body (Markdown) |
| `release_url` | `string` | URL to GitHub release page |
| `published_at` | `datetime` | When the release was published |
| `dismissed_by_id` | `bigint` | FK → `users` (admin who dismissed) |
| `dismissed_at` | `datetime` | When dismissed |
| `created_at` | `datetime` | |
| `updated_at` | `datetime` | |

**Indexes:**
- `(version)` unique
- `(dismissed_at)` — for finding active notifications

### New Models

| Model | File | Purpose |
|-------|------|---------|
| `AppUpdateNotification` | `app/models/app_update_notification.rb` | Stores discovered releases. Scopes: `active` (not dismissed), `latest`. Method: `dismiss!(admin)`. |

### New Services

| Service | File | Purpose |
|---------|------|---------|
| `AppUpdateCheckService` | `app/services/app_update_check_service.rb` | Calls GitHub Releases API, compares versions using `Gem::Version`, creates `AppUpdateNotification` for new releases. |

### New Jobs

| Job | File | Purpose |
|-----|------|---------|
| `CheckAppUpdatesJob` | `app/jobs/check_app_updates_job.rb` | Runs daily (via Solid Queue recurring schedule). Calls `AppUpdateCheckService`. |

### New Controllers

| Controller | File | Routes | Purpose |
|------------|------|--------|---------|
| `Admin::AppUpdatesController` | `app/controllers/admin/app_updates_controller.rb` | `GET /admin/app_updates`, `POST /admin/app_updates/:id/dismiss` | View available updates, dismiss notifications |

### Modified Existing Files

| File | Change |
|------|--------|
| `app/models/instance_config.rb` | Add version and update check attributes |
| `config/routes.rb` | Add `resources :app_updates` under admin namespace |
| `app/views/admin/` (dashboard layout) | Show update banner when `AppUpdateNotification.active.any?` |
| `config/recurring.yml` (Solid Queue) | Add `check_app_updates` schedule: `cron: "0 6 * * *"` (daily at 6 AM) |

### Flow: Update Check

```
CheckAppUpdatesJob runs (daily via Solid Queue)
        │
        ▼
AppUpdateCheckService.call
        │
        ├── Check InstanceConfig.current.update_check_enabled?
        │     └── false? → return early
        │
        ├── GET https://api.github.com/repos/{repo}/releases
        │     Headers: Accept: application/vnd.github+json
        │     (No auth token needed for public repos)
        │
        ├── Parse releases, filter to published (not draft/prerelease)
        │
        ├── Compare each release tag to current_app_version
        │     using Gem::Version comparison
        │
        ├── For each newer version not already in AppUpdateNotification:
        │     └── AppUpdateNotification.create!(version:, release_name:, ...)
        │
        ├── Update InstanceConfig:
        │     latest_known_version: highest release tag
        │     last_update_check_at: Time.current
        │
        └── Done
        │
        ▼
Admin visits /admin dashboard
        │
        ├── Banner: "Inferno Chat v1.2.0 is available (you're running v1.1.0)"
        │     └── Link to /admin/app_updates for details
        │
        └── Admin can dismiss or view release notes
```

### Version Comparison Logic

```ruby
# app/services/app_update_check_service.rb
class AppUpdateCheckService
  GITHUB_API = "https://api.github.com/repos/%s/releases".freeze

  def self.call
    config = InstanceConfig.current
    return unless config.update_check_enabled?

    current = Gem::Version.new(config.current_app_version.to_s.delete_prefix("v"))
    releases = fetch_releases(config.github_repo)

    releases.each do |release|
      tag = release["tag_name"].to_s.delete_prefix("v")
      next if tag.blank?

      begin
        release_version = Gem::Version.new(tag)
      rescue ArgumentError
        next # skip non-semver tags
      end

      next unless release_version > current
      next if AppUpdateNotification.exists?(version: tag)

      AppUpdateNotification.create!(
        version: tag,
        release_name: release["name"],
        release_notes: release["body"],
        release_url: release["html_url"],
        published_at: release["published_at"]
      )
    end

    config.update!(
      latest_known_version: releases.first&.dig("tag_name"),
      last_update_check_at: Time.current
    )
  end

  private

  def self.fetch_releases(repo)
    uri = URI(format(GITHUB_API, repo))
    response = Net::HTTP.get_response(uri)
    return [] unless response.code.to_i == 200

    JSON.parse(response.body).select { |r| !r["draft"] && !r["prerelease"] }
  end
end
```

---

## 7. Integration Points

### How the Eight Systems Connect

```
                    ┌──────────────────────┐
                    │   App Updates (6)     │
                    │   (standalone)        │
                    └──────────────────────┘

┌──────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  ┌─────────────┐    determines     ┌───────────────┐                │
│  │ Trust Tiers  │◄────────────────►│ Rate Limiting  │                │
│  │    (2)       │    limits for    │     (3)        │                │
│  └──────┬───────┘                  └───────┬────────┘                │
│         │                                  │                         │
│         │ tier changes      ┌──────────────┤                         │
│         │ logged            │              │ all throttle             │
│         ▼                   │              │ events logged            │
│  ┌──────────────┐           │              │                         │
│  │ Audit Logs   │◄──────────┼──────────────┘                         │
│  │    (1)       │◄────┐     │                                        │
│  └──────┬───────┘     │     │                                        │
│         ▲             │     │                                        │
│         │ payment     │     │ suspension                             │
│         │ events      │     │ broadcasts                             │
│         │             │     │                                        │
│  ┌──────┴───────┐     │  ┌──┴───────────────┐                       │
│  │ Monetization │     │  │ Content Safety   │                       │
│  │    (5)       │     │  │    (1.5)         │                       │
│  └──────┬───────┘     │  └──┬───────────────┘                       │
│         │             │     │                                        │
│         │ tier 1      │     ├── quarantine → legal holds             │
│         │ promotion   │     ├── CSAM match → audit log               │
│         └─────────────┼─►┌──┴──────────┐                             │
│                       │  │ Trust Tiers  │                            │
│                       │  │    (2)       │                            │
│                       │  └─────────────┘                             │
│                       │     ▲                                        │
│                       │     │ suspension →           ┌─────────────┐│
│                       │     │ tier demotion          │ Federation  ││
│                       │     │                        │ Security    ││
│  ┌──────────────┐     │  ┌──┴───────────────┐       │   (1.6)     ││
│  │ API Version  │─────┼─►│ Federation       │◄──────┤             ││
│  │    (4)       │     │  │ endpoints        │       │ signatures, ││
│  └──────────────┘     │  └──────────────────┘       │ E2EE, token ││
│                       │                              │ hardening   ││
│                       └── Content Safety logs all    └─────────────┘│
│                           actions                                    │
│                                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

### Specific Integration Points

| From | To | Integration |
|------|----|-------------|
| Trust Tiers (2) | Rate Limiting (3) | `RateLimitService` reads `InstanceTrustTier.tier` to determine limits |
| Trust Tiers (2) | Audit Logs (1) | `TrustEvaluationService` calls `AuditService.log` on tier changes |
| Monetization (5) | Trust Tiers (2) | `VerificationPaymentService` calls `UserTrustTier.promote!` on payment |
| Monetization (5) | Audit Logs (1) | `StripePaymentService` / `ZapPaymentService` log payment events |
| Trust Tiers (2) | Verified Benefits (2) | `UserBenefitsService` reads `UserTrustTier.tier` to decide which perks/limits apply |
| Verified Benefits (2) | InstanceConfig (existing) | `UserBenefitsService.limit_for` falls back to `InstanceConfig` defaults for non-verified users |
| Verified Benefits (2) | Servers/Channels (existing) | `requires_verification` flag gates join/access based on user tier |
| Monetization (5) | Verified Benefits (2) | Payment completion → tier 1 promotion → higher limits, gated access, and features unlock |
| Rate Limiting (3) | Audit Logs (1) | Rack::Attack `ActiveSupport::Notifications` subscriber logs throttle events |
| API Versioning (4) | All federation (existing) | All federation controllers include `ApiVersioning` concern |
| API Versioning (4) | Trust Tiers (2) | `TrustGated` concern runs on all versioned endpoints |
| Domain Block (existing) | Audit Logs (1) | `DomainBlockSnapshotService` creates snapshot + audit log entry |
| Domain Block (existing) | Trust Tiers (2) | Blocking sets `InstanceTrustTier.tier = 0` |
| Content Safety (1.5) | Audit Logs (1) | `QuarantineService`, `UserSuspensionService`, `NcmecReportService` all call `AuditService.log` for CSAM matches, suspensions, and reports |
| Content Safety (1.5) | Legal Holds (G) | `QuarantineService` auto-creates `LegalHold` records with 90-day minimum retention on CSAM quarantine |
| Content Safety (1.5) | Trust Tiers (2) | `FederationSuspensionService` may demote or blocklist an instance's trust tier based on incoming CSAM suspension notifications |
| Content Safety (1.5) | Moderation Reports (existing) | `QuarantineService` auto-creates `ModerationReport` with `type: csam, priority: 2`. Enhanced moderation queue prioritizes CSAM reports. |
| Content Safety (1.5) | NIP-56 (existing) | One-click CSAM action publishes NIP-56 report event to connected relays |
| Content Safety (1.5) | Instance Blocklist (existing) | One-click CSAM action for remote users blocks the offending user's home domain |
| Content Safety (1.5) | Message Pruning (existing) | `LegalHold` integration prevents pruning of quarantined content. `UserSuspension` content hiding uses query scopes (not deletion). |
| Content Safety (1.5) | Devise Auth (existing) | `Suspendable` concern overrides `active_for_authentication?` using denormalized `suspended_at` column for O(1) auth check |
| Federation Suspensions (1.5) | Federation Endpoints (existing) | `Federation::SuspensionsController` receives incoming suspension notifications via `/federation/suspensions/notify` |
| Message Signatures (1.6) | Audit Logs (1) | Signature verification failures are logged via `AuditService.log` with event type `signature_verification_failed` |
| Message Signatures (1.6) | Content Safety (1.5) | Signed messages cannot be tampered with before hash scanning — signature verification ensures content integrity through the scanning pipeline |
| E2EE DMs (1.6) | Content Safety (1.5) | E2EE DMs are encrypted client-side so server-side CSAM scanning cannot inspect them — documented trade-off (provider cannot scan what it cannot see) |
| Token Hardening (1.6) | Trust Tiers (2) | Token scope is tied to trust tier: Tier 3 gets `profile_read` only, Tier 1 gets `full` scope |
| Token Hardening (1.6) | Rate Limiting (3) | Shorter tokens + silent refresh generates more token verify calls — rate limit token refresh endpoint accordingly |
| NIP-05 Enforcement (1.6) | Federation Auth (existing) | When `require_nip05_for_federation` is enabled, blocks remote auth from users whose NIP-05 cannot be verified |

### Shared Concerns Applied to Controllers

| Concern | Applied To | Purpose |
|---------|-----------|---------|
| `TrustGated` | All `Federation::*` controllers, all `Api::V1::Federation::*` controllers | Reject tier 0, inject tier into env |
| `ApiVersioning` | All `Federation::*` controllers (deprecation headers), all `Api::V1::*` controllers (version headers) | Version negotiation and deprecation |
| `RateLimitHeaders` | `ApplicationController` (or federation controllers only) | `X-RateLimit-*` response headers |
| `BenefitGated` | `CustomThemesController`, `InvitesController`, `ChannelsController` | Reject if user is not tier 1 or specific perk is disabled. Gates server join and channel access when `requires_verification` is set. |
| `Suspendable` | `User` model | Overrides Devise `active_for_authentication?` to block suspended users. Adds `suspended?`, `active`/`suspended` scopes. |
| `ScannableUpload` | `MessagesController`, `ServerEmojisController`, `ServerStickersController` | `after_action` that detects new image blobs and enqueues `UploadScanJob`. Only active when `upload_scanning_enabled`. |

---

## 8. Phased Implementation Order

### Phase A: Audit Logging (Foundation)

**Dependencies:** None (builds on existing models)

**Deliverables:**
- `FederationAuditLog` model + migration
- `AuditService` with `log()` method
- Integrate `AuditService.log` calls into existing auth, federation, and blocklist flows
- Admin audit log viewer (`/admin/audit_logs`)

**Why first:** Every subsequent system generates audit events. Having the logging infrastructure in place means all tier changes, payments, and rate limit events are captured from day one.

**Estimated scope:** 1 migration, 2 models, 1 service, 1 controller, modify 4 existing files.

---

### Phase A.5: Content Safety (CSAM Detection, Upload Scanning & Bad Actor Handling)

**Dependencies:** Phase A (CSAM matches, quarantines, suspensions, and NCMEC submissions are all audit-logged via `AuditService`)

**Sub-phases:**

#### Phase A.5a: Content Type Validation + User Suspensions (no dependencies beyond Phase A)

**Deliverables:**
- `UserSuspension` model + migration
- `Suspendable` concern (mixed into `User`)
- Add `suspended_at` column to `users` table
- `UserSuspensionService` (suspend/lift + session invalidation + content hiding)
- `LiftExpiredSuspensionsJob` (recurring hourly via Solid Queue)
- `Admin::UserSuspensionsController`
- Content type validation on `MessagesController` file attachments (reject disallowed MIME types)
- Wire `AuditService.log` calls into suspension events

**Why first within A.5:** User suspensions are independently useful (spam, harassment cases) and don't depend on scanning infrastructure. Content type validation is a standalone safety improvement.

**Estimated scope:** 2 migrations, 1 model, 1 concern, 1 service, 1 controller, 1 job, modify 3 existing files.

#### Phase A.5b: Hash Tables + Scan Service + Scan Job + Concern (needs Phase A for AuditService)

**Deliverables:**
- `ContentHash` + `KnownBadHash` models + migrations
- `UploadScanService` (SHA-256 + pHash computation and matching)
- `ContentHashImportService` (bulk import known-bad hashes)
- `UploadScanJob` (async scan wrapper)
- `ScannableUpload` concern (after_action on upload controllers)
- `Admin::KnownBadHashesController` (manage hash database)
- Add `dhash-vips` gem to Gemfile
- Add scanning config columns to `instance_configs`
- Wire `ScannableUpload` into `MessagesController`, `ServerEmojisController`, `ServerStickersController`

**Why second:** Scanning infrastructure must exist before quarantine can work. Import service lets admins seed the known-bad hash database.

**Estimated scope:** 3 migrations, 2 models, 2 services, 1 concern, 1 controller, 1 job, 1 gem, modify 4 existing files.

#### Phase A.5c: Quarantine + Enhanced Moderation Workflow + Escalation (needs A.5b)

**Deliverables:**
- `QuarantinedUpload` model + migration
- `QuarantineService` (orchestrate quarantine + auto-report + auto-hold + auto-suspend)
- `CsamEscalationService` (escalate overdue CSAM reports)
- `CsamEscalationJob` (recurring every 30 min via Solid Queue)
- `AdminMailer#csam_escalation` mailer
- `Admin::QuarantinedUploadsController` (review queue + one-click CSAM action panel)
- Add `priority`, `escalated`, `escalated_at` columns to `moderation_reports`
- Add `csam` to `REPORT_TYPES`
- Enhanced moderation report ordering (priority DESC, created_at ASC)
- Wire `QuarantineService` into `UploadScanJob` on match

**Why third:** Quarantine depends on the scanning pipeline (A.5b) detecting matches. Escalation and enhanced moderation workflows depend on quarantine records existing.

**Estimated scope:** 2 migrations, 1 model, 2 services, 1 mailer, 1 controller, 1 job, modify 3 existing files.

#### Phase A.5d: NCMEC Reporting (needs A.5c)

**Deliverables:**
- `NcmecReport` + `NcmecReportAttachment` models + migrations
- `NcmecReportService` (build + submit CyberTipline reports)
- `NcmecReportJob` (async submission)
- `Admin::NcmecReportsController` (view, draft, submit, track reports)
- Add NCMEC config columns to `instance_configs` (`ncmec_api_enabled`, `ncmec_provider_id`)
- `Admin::ContentSafetyConfigController` (configure all content safety settings)

**Why fourth:** NCMEC reporting depends on quarantined uploads existing (A.5c) since reports reference quarantined evidence. Config controller is added here as it covers all content safety settings.

**Estimated scope:** 2 migrations, 2 models, 1 service, 2 controllers, 1 job, modify 1 existing file.

#### Phase A.5e: Federation Suspension Notifications + Trust Tier Integration (needs Phase B)

**Deliverables:**
- `FederationSuspensionNotification` model + migration
- `FederationSuspensionService` (broadcast/receive suspension notifications)
- `FederationSuspensionBroadcastJob` (async broadcast to peers)
- `Federation::SuspensionsController` (receive incoming notifications)
- Add federation suspension config columns to `instance_configs`
- Wire incoming suspensions into trust tier evaluation (demote/blocklist based on CSAM notifications)
- Wire outgoing suspensions into `UserSuspensionService`

**Why last within A.5:** Federation suspension propagation depends on trust tiers (Phase B) to evaluate incoming notifications and apply tier impacts. This sub-phase bridges content safety with the federation trust system.

**Estimated scope:** 1 migration, 1 model, 1 service, 1 controller, 1 job, modify 3 existing files.

---

### Phase A.6: Federation Security (Threat Model & Cryptographic Protections)

**Dependencies:** Phase A (signature verification failures are audit-logged)

**Sub-phases:**

#### Phase A.6a: Message Signatures (no dependencies beyond existing models)

**Deliverables:**
- Add `nostr_event_id` (string) and `signature` (string) columns to `messages` table
- `MessageSigningService` (sign on create, verify on display)
- Wire `MessageSigningService.sign` into message creation flow
- Wire `MessageSigningService.verify` into message display (verification badge / unverified warning)
- Wire signature verification failures into `AuditService.log`

**Why first within A.6:** Message signing is the highest-priority mitigation (closes the HIGH-severity content spoofing gap) and has no dependencies beyond existing models and services.

**Estimated scope:** 1 migration, 1 service, modify 3 existing files.

#### Phase A.6b: Token & Identity Hardening (no dependencies beyond Phase A)

**Deliverables:**
- `RevokedFederationToken` model + `revoked_federation_tokens` migration
- `FederationTokenRefreshService` (silent refresh with revocation check)
- Add `require_nip05_for_federation` (boolean) and `federation_token_ttl_hours` (integer) to `instance_configs`
- Modify `FederationTokenService` — reduce TTL, check revocation table, add scope to payload
- Modify `NostrAuthController` — enforce NIP-05 when configured
- Modify `HasNostrIdentity` — per-user key derivation via HKDF
- Wire conversation reference signing into `push_conversation_reference`

**Why second:** Token hardening and NIP-05 enforcement are independent of message signing and can be developed in parallel. Per-user key derivation is backwards-compatible (re-encrypt on next access).

**Estimated scope:** 1 migration, 1 model, 1 service, modify 4 existing files.

#### Phase A.6c: NIP-44 E2EE DMs (needs A.6a for signing infrastructure)

**Deliverables:**
- Add `encrypted_content` (text) and `encrypted_content_nonce` (string) columns to `messages` table
- `Nip44Service` (Ruby-side encrypt/decrypt for tooling and verification)
- Client-side encryption in Stimulus controller using `nostr-tools` NIP-44
- Client-side decryption on message display
- Fallback handling for unencrypted DMs (gradual rollout, opt-in per conversation)

**Why last within A.6:** E2EE is the most complex layer and can ship after federation launch since messages are already protected by signatures (A.6a). E2EE is the final layer that closes the DM snooping gap.

**Estimated scope:** 1 migration, 1 service, modify 3 existing files (Ruby) + 2 existing files (JS/Stimulus).

---

### Phase B: Trust Tiers + Verified User Benefits

**Dependencies:** Phase A (tier changes are audit-logged)

**Deliverables:**
- `InstanceTrustTier` + `UserTrustTier` + `FederationTosVersion` models + migrations
- `VerifiedUserBenefit` singleton model + migration
- `CustomTheme` model + migration
- Add `requires_verification` boolean to `servers` and `channels` tables
- `TrustEvaluationService` + `FederationTosService` + `UserBenefitsService`
- `TrustGated` + `BenefitGated` concerns
- Admin trust tier management UI
- Admin verified benefits configuration UI
- Custom themes controller
- Federation ToS endpoint
- Wire into existing auth flow (auto-create tier records, increment counters)
- Wire `UserBenefitsService` into `InstanceConfig` limit checks and server emoji/sticker limits
- Wire gated server/channel checks into join and access flows

**Why second:** Rate limiting, monetization, and API versioning all depend on tiers existing. Benefits are part of the tier system — they define what users get for verifying.

**Estimated scope:** 6 migrations, 6 models, 3 services, 2 concerns, 4 controllers, modify 10 existing files.

---

### Phase C: Rate Limiting by Tier

**Dependencies:** Phase B (needs tier records to determine limits)

**Deliverables:**
- `RateLimitService`
- `TrustTierMiddleware`
- `RateLimitHeaders` concern
- Rewrite `rack_attack.rb` with dynamic tier-aware throttles
- Add `rate_limits` JSONB column to `instance_configs`
- Admin UI for configuring rate limits per tier

**Why third:** With tiers in place, rate limiting becomes meaningful. Untrusted instances get restricted; verified ones get generous limits.

**Estimated scope:** 1 migration, 1 service, 1 middleware, 1 concern, modify 3 existing files.

---

### Phase D: API Versioning

**Dependencies:** Phase B (versioned endpoints use `TrustGated`), Phase C (`RateLimitHeaders`)

**Deliverables:**
- `ApiVersioning` concern
- `Api::V1::Federation::BaseController` + all v1 federation controllers
- Versioned routes in `config/routes.rb`
- Deprecation headers on legacy `/federation/*` routes
- Update `FederationService` to try v1 paths first with legacy fallback

**Why fourth:** Versioning wraps the existing federation API. All new endpoints (ToS, trust, payments) go directly into v1.

**Estimated scope:** 1 concern, 7 controllers (thin wrappers), modify 2 existing files.

---

### Phase E: Monetization

**Dependencies:** Phase B (tier promotion), Phase A (payment audit logging), Phase D (payment endpoints live under v1)

**Deliverables:**
- `PaymentRecord`, `InstancePaymentConfig`, `StripeCustomer` models + migrations
- `StripePaymentService`, `ZapPaymentService`, `VerificationPaymentService`, `InstanceFeeService`
- Payment controllers (Stripe, Zaps, Verification, Admin config)
- `CheckLightningPaymentJob`, `ExpireUnpaidInvoicesJob`
- User-facing verification page
- Admin payment configuration and revenue dashboard
- Add `stripe` gem to Gemfile

**Why fifth:** Payments are the most complex system and depend on tiers (what you're paying for), audit logging (recording payments), and API versioning (endpoint structure).

**Estimated scope:** 3 migrations, 3 models, 4 services, 5 controllers, 2 jobs, 1 gem.

---

### Phase F: App Updates

**Dependencies:** None (fully standalone, but nice to ship last)

**Deliverables:**
- `AppUpdateNotification` model + migration
- `AppUpdateCheckService`
- `CheckAppUpdatesJob` (recurring via Solid Queue)
- Version columns on `instance_configs`
- Admin update notification UI + dashboard banner

**Why last:** Completely independent of other systems. Can be implemented at any time, but shipping last means admins get update notifications for all the new features above.

**Estimated scope:** 1 migration, 1 model, 1 service, 1 job, 1 controller, modify 2 existing files.

---

### Phase G: Legal Compliance (can run parallel to E/F)

**Dependencies:** Phase A (audit logging must exist)

**Deliverables:**
- `LegalHold`, `DataExport`, `DomainBlockSnapshot` models + migrations
- `DataExportService`, `DomainBlockSnapshotService`
- Admin legal hold and data export controllers
- Wire legal holds into message pruning job
- Wire domain block snapshots into `InstanceBlocklist` callbacks

**Estimated scope:** 2 migrations, 3 models, 2 services, 2 controllers, modify 2 existing files.

---

### Dependency Graph

```
Phase A: Audit Logging ──────────────────────────────────┐
    │                                                    │
    ├── Phase A.5a: User Suspensions + Content Validation│
    │       │                                            │
    │       ▼                                            │
    ├── Phase A.5b: Hash Tables + Scan Pipeline          │
    │       │                                            │
    │       ▼                                            │
    ├── Phase A.5c: Quarantine + Moderation + Escalation │
    │       │                                            │
    │       ▼                                            │
    ├── Phase A.5d: NCMEC Reporting                      │
    │                                                    │
    ├── Phase A.6a: Message Signatures                   │
    │       │                                            │
    │       ▼                                            │
    ├── Phase A.6c: NIP-44 E2EE DMs                      │
    │       (needs A.6a for signing infra)               │
    │                                                    │
    ├── Phase A.6b: Token & Identity Hardening           │
    │       (independent — parallel to A.6a)             │
    │                                                    │
    ▼                                                    ▼
Phase B: Trust Tiers + Benefits                   Phase G: Legal Compliance
    │   (tiers, perks, personal                    (can run parallel to E/F)
    │    emojis/stickers/themes)
    │
    ├── Phase A.5e: Federation Suspension Notifications
    │       (bridges content safety ↔ trust tiers)
    │
    ├──────────────────┐
    ▼                  ▼
Phase C: Rate Limits   Phase D: API Versioning
    │                  │
    └────────┬─────────┘
             ▼
      Phase E: Monetization
        (payment → tier 1 → benefits unlock)

Phase F: App Updates (independent — can ship anytime)
```

### Total New Database Tables

| Table | Phase |
|-------|-------|
| `federation_audit_logs` | A |
| `user_suspensions` | A.5a |
| `content_hashes` | A.5b |
| `known_bad_hashes` | A.5b |
| `quarantined_uploads` | A.5c |
| `ncmec_reports` | A.5d |
| `ncmec_report_attachments` | A.5d |
| `federation_suspension_notifications` | A.5e |
| `revoked_federation_tokens` | A.6b |
| `instance_trust_tiers` | B |
| `user_trust_tiers` | B |
| `federation_tos_versions` | B |
| `verified_user_benefits` | B |
| `custom_themes` | B |
| `payment_records` | E |
| `instance_payment_configs` | E |
| `stripe_customers` | E |
| `app_update_notifications` | F |
| `legal_holds` | G |
| `data_exports` | G |
| `domain_block_snapshots` | G |

### Total Modified Existing Tables

| Table | Column(s) Added | Phase |
|-------|----------------|-------|
| `users` | `suspended_at` (datetime) | A.5a |
| `moderation_reports` | `priority` (integer), `escalated` (boolean), `escalated_at` (datetime) | A.5c |
| `instance_configs` | `upload_scanning_enabled`, `phash_threshold`, `auto_quarantine_enabled`, `auto_suspend_on_csam` | A.5b |
| `instance_configs` | `ncmec_api_enabled`, `ncmec_provider_id`, `csam_escalation_hours` | A.5d |
| `instance_configs` | `federation_suspension_broadcast_enabled`, `federation_suspension_auto_action` | A.5e |
| `messages` | `nostr_event_id` (string), `signature` (string) | A.6a |
| `messages` | `encrypted_content` (text), `encrypted_content_nonce` (string) | A.6c |
| `instance_configs` | `require_nip05_for_federation` (boolean, default true), `federation_token_ttl_hours` (integer, default 24) | A.6b |
| `servers` | `requires_verification` (boolean, default false) | B |
| `channels` | `requires_verification` (boolean, default false) | B |
| `instance_configs` | `rate_limits` (jsonb) | C |
| `instance_configs` | `current_app_version`, `latest_known_version`, `last_update_check_at`, `update_check_enabled`, `github_repo` | F |

### New Gems

| Gem | Phase | Purpose |
|-----|-------|---------|
| `dhash-vips` | A.5b | Perceptual hashing (dHash) via `ruby-vips` — reuses existing `image_processing` vips bindings, no new native C dependency |
| `stripe` | E | Stripe API client |

All other functionality uses existing gems (`rack-attack`, `paper_trail`, `nostr_ruby`, `sidekiq`/Solid Queue, `image_processing`/`ruby-vips`).
