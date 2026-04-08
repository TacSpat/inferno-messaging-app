# Content Safety Overhaul -- Flutter Implementation

## Design Philosophy

**Seatbelt, not a locked door.** You can't stop a determined kid from joining an "adult" server -- every parental control in history has been bypassed by 12-year-olds. The goal is to ensure that when users are *anywhere* in the app, the worst content doesn't reach them unsolicited. Passive protection that's always on, not gatekeeping they can disable.

**Two audiences:**
1. **Regular users** -- see almost nothing. A protection level toggle and a hidden-messages review list. Done.
2. **Server admins** -- guided onboarding wizard that sets safe defaults based on server type. Age-gating tools for 18+ servers.

There is no instance admin panel. Advanced tuning (reputation thresholds, shared hash config, CSAM list updates, NSFW model thresholds) are hardcoded defaults shipped in the codebase. They change when you push a release tag and clients update. This keeps the system consistent across all users and avoids misconfiguration.

**Kids are not stupid.** They will find ways around age gates and content filters to get into servers where their friends are. Every parental control ever built has been defeated by 12-year-olds. The system doesn't try to prevent this. Instead, it ensures that *wherever* a user ends up -- even in an "adult" server they bypassed verification for -- the worst unsolicited content (CSAM, predatory DMs, spam from strangers) is still caught by passive protections that can't be turned off.

---

## Part 0: Day-One Cold Start Problem

### The vulnerability
Day one, the shared hash network is empty, the CSAM table is empty, and every user is unprotected by hashing until *someone* hides something first. The first users to encounter harmful content ARE the protection for everyone after them. Someone has to see it first.

### Defenses that work without data (day-one ready)
These require zero hash data to function -- they work the moment the app is installed:

1. **NSFW detection model** -- The ONNX classifier ships with the app bundle. It is a pre-trained model, not a database. It classifies images locally on day one with zero data needed. This is the strongest day-one protection for explicit content.
2. **Unknown sender holding** -- No data needed. Messages from non-friends are held/filtered by default in Standard mode. Pure policy, works immediately.
3. **Synchronous image checking** -- Even without hashes to match against, the infrastructure ensures non-friend images go through the check pipeline before rendering. When hashes DO exist, they are caught before display.
4. **Spam preset filters** -- Block links, phone numbers, ALL CAPS, repeated characters. Pattern matching, no database needed.

### Seeding the hash database before launch
Before the first public release, manually populate the hash table:
- Import known-bad image hashes from open sources (StopNCII, community lists) into the `csam_hash_entries` Drift table
- Use your own testing to generate perceptual hashes from test images
- The table doesn't start at zero -- it starts at whatever you can seed before shipping

### Making hiding feel impactful
The first reporters are the most valuable users in the network. Hiding harmful content should feel like a contribution, not just housekeeping:
- **Instant feedback on hide:** "This image's fingerprint has been shared with the network to protect other users."
- **Quiet acknowledgment:** A subtle note in safety settings: "You've helped protect the network from N harmful images" -- not gamified, no leaderboards, no badges. Just recognition that the action mattered.
- The goal is to make users feel like hiding is worth doing -- not just for their own feed, but for everyone.

### The compounding effect
The hash network is a compounding defense. Day one it is thin. By week two, early adopters have seeded it. By month three, the most common harmful images are caught before anyone new sees them. The longer the network runs, the stronger it gets. The day-one gap is real but temporary, and the other filters cover it.

---

## Part 0b: Rotten Servers and Bad Actors

### The reality of decentralization
Anyone can run a server. That includes terrorists, pedophiles, and crime organizations. In a federated system, you cannot prevent bad servers from existing. Attempting to maintain a "bad server blacklist" is centralized moderation with extra steps -- someone has to decide which servers are bad, and that someone becomes a single point of control and failure.

### Why the trust graph naturally isolates bad actors

The shared hash network operates at the **individual pubkey level**, not the server level. This is critical:

- **Bad actors don't end up in good users' friend lists.** The trust weighting means their reports carry almost no weight (0.1 per stranger). A cluster of criminals friending each other and coordinating reports only affects... each other.
- **Poisoning the hash network is impractical.** To affect a stranger's client, you need 30+ coordinated Nostr accounts all reporting the same hash. Even then, the user can unhide false positives, which allowlists the hash permanently.
- **The network is defensive, not authoritative.** Each client decides for itself what to block based on its *own* trust graph. There is no central authority a rotten server can manipulate.
- **Your trust graph IS your protection.** If you have good friends, you are well protected. The system reflects the quality of your social network, not a global moderation decision.

### What you can do
- **Users are protected passively** regardless of what server they are in -- CSAM checking, NSFW detection, unknown sender filtering, image hashing all run on-device
- **Server discovery is opt-in** -- rotten servers won't mark themselves discoverable
- **The report-to-authorities flow** gives users a clear path when they encounter illegal activity

### What you deliberately don't do
- No server-level reputation or blacklists
- No centralized "bad server" registry
- No attempt to shut down or block servers -- that is centralized thinking
- No cross-server moderation authority

The protection model is: bad servers can exist, but they can't project harm outward through the network because the trust graph isolates them at the individual level.

---

## Part 0c: First-Contact DM Protection

### The most dangerous moment
The first message from a stranger is the highest-risk interaction, especially for younger users. A predator's first DM is where the damage starts.

### Current state
Conversations from non-contacts already go through an accept/decline request queue. But the message content (including images and links) is visible in the preview before the user accepts.

### New behavior
For DM requests from non-contacts (no friend relationship):
- **Strip images and links from the preview.** The user sees "Someone wants to message you" with the text content only -- no inline images, no clickable links.
- **Images are held through the safety pipeline** before the conversation is even accepted. If they match CSAM/blocked hashes or the NSFW model flags them, the conversation request is auto-hidden before the user ever sees it.
- **If the user accepts the conversation**, images and links render normally going forward (they have chosen to engage with this person).
- **First message from stranger with ONLY images and no text** shows: "This person sent you an image. Accept the conversation to view it." -- never auto-displays stranger images in request previews.

This means a predator sending unsolicited images to strangers hits a wall: the image never renders unless the target explicitly accepts the conversation, and if the image matches any safety filter, the request is silently hidden.

---

## Part 1: Simplified User Safety Settings

### Current Problem
Exposing 15+ toggles, number inputs, sensitivity dropdowns, and scoring formulas is hostile to regular users. The reputation system explanation alone is a paragraph of text about penalty caps and signal weights.

### New Design

**The user sees:**
```
CONTENT PROTECTION
  [Standard v]     <-- dropdown: Standard / Relaxed

  Standard: Blocks harmful images, filters spam, holds messages
            from unknown senders. Recommended for most users.

  Relaxed:  Image protection stays on. Spam filtering and
            unknown sender holds are turned off.

HIDDEN MESSAGES
  [list of auto-hidden messages with Unhide buttons]
```

That is it. Two choices. One list.

### What each mode maps to internally

| Setting | Standard | Relaxed |
|---------|----------|---------|
| `safetyImageHashEnabled` | true | true |
| `safetySharedHashesEnabled` | true | true |
| `safetyPublishHashes` | true | true |
| `safetyHideUnknownSenders` | true | false |
| `safetyBlockLinks` | true | false |
| `safetyBlockPhoneNumbers` | true | false |
| `safetyBlockAllCaps` | true | false |
| `safetyBlockSpamChars` | true | false |
| `safetyReputationEnabled` | true | false |
| `safetyReputationThreshold` | 30 | 30 |
| `safetyReputationSensitivity` | moderate | moderate |
| `safetyReportThreshold` | 3 | 0 |
| CSAM hash list checking | **always on** | **always on** |
| NSFW image detection | true | true |

**Key:** Image protection and CSAM list are always on in both modes. You cannot disable them. The CSAM check has no toggle -- it is hardcoded.

### What happens to the keyword filter
The user-facing keyword list goes away from the main settings. The preset checks (block links, block phones, block caps, block spam) are toggled automatically by the protection mode. The custom word list stays in code as a hardcoded default that ships with updates -- no user-facing editor.

### Implementation

**Storage:** All safety settings live in the `app_settings` Drift table as key-value pairs. The `safetyProtectionLevel` key stores `"standard"` or `"relaxed"`.

**Files:**
- `lib/screens/settings/safety_screen.dart` -- fire shield toggle dropdown + hidden messages list
- `lib/services/content_safety_service.dart` -- `applyProtectionLevel()` method that writes all individual toggle values to `app_settings` based on the selected level

---

## Part 2: Harmful Content Hash Database

### Why it works for a decentralized app
The hash database sits locally in a Drift table on the user's device. Images are compared on the user's own machine. Nothing leaves the device. No API call, no cloud service, no third party sees the content. It is the user's own client choosing not to display known illegal material.

### Hash sources (realistic, no licensing barriers)

**Primary: The shared hash network (already being built)**
When any Inferno user hides harmful content, those image hashes propagate through Nostr relays via NIP-56 Kind 1984 report events with `["x"]` tags. Over time this becomes a crowdsourced blocklist. Trust-weighted confidence scoring prevents abuse. This is the main mechanism -- it grows organically with the user base and requires zero external dependencies.

**Secondary: Open/public hash lists**
Some organizations publish hash lists without formal applications:
- **StopNCII.org** -- public API for non-consensual intimate image hashes
- **Open-source community-curated lists** -- projects that maintain freely available hash databases
- Any future open lists can be added by shipping a new list source in a release

**Future-proofed: Provider lists (if ever obtained)**
The table is designed to accept hashes from any source. If you ever establish a relationship with NCMEC, IWF, or Project VIC, their hashes slot right in. But the system doesn't depend on this -- it works without it.

**Why not NCMEC/IWF right now?**
These providers license hash databases to *organizations*, not individual end users. They require applications, legal agreements, compliance audits, and reporting obligations. A decentralized client-side app where each user runs their own instance doesn't fit their model. Designing around this dependency would block the entire safety system on a bureaucratic process that may never complete.

### Implementation approach

**Drift table: `csam_hash_entries`** (separate from `content_hashes` -- this is a reference database, not user-generated)
```dart
class CsamHashEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get hashValue => text()();
  TextColumn get hashType => text()();       // "md5", "sha1", "phash", "dhash"
  TextColumn get listSource => text().nullable()(); // "shared_network", "stopncii", "community", "custom"
  DateTimeColumn get addedAt => dateTime().nullable()();

  @override
  List<Set<Column>> get uniqueKeys => [{hashValue, hashType}];
}
```

**Feeding from the shared hash network:**
- When a shared `ContentHash` reaches high confidence (many trusted reporters) AND was reported with a severe reason (e.g., the NIP-56 report content is "illegal" or "csam"), it gets promoted into `CsamHashEntries` automatically
- This means the shared network is not just blocking future matches via `content_hashes` -- the worst content gets elevated to the permanent, non-overridable CSAM table
- Promotion threshold is hardcoded (e.g., confidence >= 5.0 with at least 2 friend reporters or 15+ strangers)

**Feeding from open lists:**
- A periodic background isolate task fetches from configured open list URLs and upserts entries into the Drift table
- List URLs are hardcoded in the app and updated via release tags
- Ships with StopNCII integration if their API is accessible; other lists added as they become available

**Checking flow:**
1. Image arrives (via Nostr relay subscription or message decryption)
2. **Before rendering** (synchronous for non-friend senders, async for friends): compute dHash using the `image` Dart package (9x8 grayscale, 64-bit hex)
3. Check against `csam_hash_entries` table -- if match, the message is **permanently hidden** by setting `hiddenAt` and `hiddenReason = "csam_match"` on the message row
4. CSAM-matched messages cannot be unhidden via the normal UI. No allowlisting. No appeals through the settings screen.
5. The hidden message entry shows "This message was blocked by automated safety systems" with no preview of the content

**Non-negotiable behaviors:**
- Cannot be disabled by any user setting or protection level
- CSAM-matched `content_hashes` entries cannot be allowlisted (guard in the allowlist method)
- No content preview in the hidden messages list for CSAM matches
- Matched hashes are automatically published to the shared hash network via NIP-56 Kind 1984 events to protect other users

---

## Part 3: Synchronous Image Checking for Non-Friends

### Current Problem
If image hashing runs asynchronously after the message is inserted into the Drift database, the image renders in chat, then gets hidden moments later. For harmful content from strangers, that window is the entire problem.

### New Flow

**For messages from non-friends (no accepted contact relationship):**
1. Message arrives from relay with image attachments
2. `ContentSafetyService.check()` runs its 6-stage pipeline
3. **Before the message is marked as renderable**, run image hash check synchronously
4. If hash matches CSAM list or existing blocked hash -- set `hiddenAt`/`hiddenReason` immediately, never display
5. If hash doesn't match -- render normally, store hash async for future matching

**For messages from friends:**
- Keep current async flow (trust but verify in background)
- Friends' images still get hashed for the database but are not held

### Implementation

**File:** `lib/services/content_safety_service.dart`
- The 6-stage pipeline: CSAM hash check, NSFW model check, unknown sender filter, report threshold check, reputation score check, image hash (shared network) check
- For non-friend senders: the CSAM hash and NSFW stages run synchronously before the message widget builds
- For friend senders: all stages run asynchronously after display
- The `check()` method returns a `SafetyResult` with `hidden`, `reason`, and `shouldPublishHash` fields

**File:** `lib/widgets/message_bubble.dart`
- Message rendering checks `message.hiddenAt != null` before building content
- Hidden messages show a collapsed placeholder with the hide reason

---

## Part 4: Local NSFW Detection

### Approach
Use a lightweight on-device model to flag explicit images before display. No cloud API, keeps everything private. All processing happens on-device via ONNX Runtime through Dart FFI bindings.

### Two-stage pipeline

**Stage 1: Pre-filter (Marqo ViT-Tiny)**
A small, fast vision transformer (~5MB) that runs on every image. High recall, moderate precision. If it scores below the safe threshold, the image passes without hitting stage 2. This keeps the common case (safe images) fast.

**Stage 2: Confirmation (TostAI FocalNet-Base)**
A larger, more accurate classifier (~80MB) that only runs on images flagged by stage 1. High precision. This reduces false positives from the pre-filter. Only images that pass both stages are flagged as NSFW.

### Implementation

**File:** `lib/services/noise_processor.dart`
```dart
class NoiseProcessor {
  static const _preFilterModelPath = 'assets/models/vit_tiny_nsfw.onnx';
  static const _confirmModelPath = 'assets/models/focalnet_base_nsfw.onnx';

  /// Returns true if the image is classified as explicit.
  /// Stage 1 runs always; stage 2 runs only if stage 1 flags.
  Future<bool> isExplicit(Uint8List imageBytes, {double threshold = 0.7});

  /// Returns detailed classification scores from both stages.
  Future<NsfwResult> classify(Uint8List imageBytes);
}
```

The ONNX models are loaded via `onnxruntime` FFI bindings. Model files ship in the app's asset bundle. Inference runs on a background isolate to avoid blocking the UI thread.

**Integration with ContentSafetyService:**
- NSFW check is stage 2 in the 6-stage pipeline (after CSAM hash, before unknown sender filter)
- For non-friend senders: runs synchronously (same as CSAM check)
- For friend senders: runs async
- Auto-hides with reason `"auto:nsfw"`
- NSFW-hidden messages CAN be unhidden (unlike CSAM) -- they are inappropriate, not illegal

**Server-level interaction:**
- Servers marked as 18+ skip NSFW filtering for their channels (the content is expected)
- DMs always get NSFW checked regardless of server context
- NSFW detection is on in both Standard and Relaxed modes

---

## Part 5: Server Admin Onboarding Wizard

### Current Problem
Server creation is: pick a name, upload an icon, done. Admin gets an empty server with a "general" channel and has to figure out roles, safety, channels, and invites on their own. No guidance on content policies.

### New Server Creation Flow

**Step 1: Name and Icon** (existing, keep as-is)

**Step 2: Server Type** (NEW)
```
What kind of server is this?

  ( ) Community        Public-facing community. Open invites, discoverable.
  ( ) Friends & Family Private group. Invite-only, not discoverable.
  ( ) Gaming           Game-focused. Voice channels, LFG, screenshots.
  ( ) Work / Team      Professional. Projects, standups, announcements.
  ( ) 18+ Community    Age-restricted. Requires member verification.
```

**Step 3: Channels** (NEW -- template based on type)

Show a pre-built channel structure the admin can customize:

| Type | Default Channels |
|------|-----------------|
| Community | welcome (read-only), rules (read-only), general, off-topic, media, announcements (mod-only) |
| Friends & Family | general, photos, voice-hangout |
| Gaming | general, lfg, screenshots, clips, voice-lobby-1, voice-lobby-2 |
| Work / Team | general, announcements (mod-only), standup, projects, random |
| 18+ Community | verification-submit (post-only, no history), rules (read-only), general, media, voice |

Admin can add/remove/rename channels before confirming. The templates are suggestions, not requirements.

**Step 4: Server Rules** (NEW)
```
Set your server rules (recommended)

  [Pre-filled template based on server type]

  These will be posted in your #rules channel and shown to
  new members when they join.
```

Templates vary by type. 18+ template includes age policy language.

**Step 5: Done**
```
Your server is ready!

  -> Invite members: [copy invite link]
  -> Customize further in Server Settings
```

### What the server type auto-configures

| Setting | Community | Friends | Gaming | Work | 18+ |
|---------|-----------|---------|--------|------|-----|
| Discoverable | true | false | false | false | false |
| Default roles | Admin, Mod, Member | Admin, Member | Admin, Mod, Member | Admin, Manager, Member | Admin, Mod, Verified, Member |
| Welcome message | on | on | on | on | on (with age notice) |
| `ageRestricted` | false | false | false | false | **true** |
| Verification required | no | no | no | no | **yes** |
| NSFW filter in channels | on | on | on | on | **off** (expected content) |

### Implementation

**Files:**
- `lib/widgets/add_server_dialog.dart` -- extend into multi-step wizard with type selection and channel templates
- `lib/services/server_publish_service.dart` -- `applyServerTemplate(type)` method that publishes channels, roles, rules as Nostr events
- The `serverType` and `ageRestricted` fields are stored as tags in the server's Nostr replaceable event

---

## Part 6: Age-Restricted Servers

### The honest reality
An "Are you 18?" checkbox does nothing protective. A determined kid clicks yes. But it serves two purposes:
1. Establishes intent -- the admin asked, the user affirmed
2. Creates a friction point that stops casual/accidental exposure

The real protection comes from **mod-verified gating**: a human reviews the request before granting access.

### Two-tier system

**Tier 1: Age Gate (automatic)**
- Server is marked `ageRestricted: true` in its Nostr metadata event
- When a user tries to join (via invite or discovery), they see a confirmation:
  ```
  This server is age-restricted (18+)

  By continuing, you confirm that you are 18 years of age or older.

  [Cancel]  [I am 18 or older]
  ```
- Clicking confirm is logged locally (timestamp + pubkey)
- User joins with the base role (restricted -- can only see #verification-submit)

**Tier 2: Mod Verification (gated access)**
- After joining, user lands in #verification-submit -- a special channel where:
  - Users CAN post (submit their verification)
  - Users CANNOT see message history (other people's submissions)
  - Only mods can read the full history
- The admin defines what "verification" means for their server (selfie with username, ID with birthdate redacted, just a conversation -- up to them)
- A mod grants the `Verified` role -- user gains access to all regular channels
- Until verified, the user can only see #rules (read-only) and #verification-submit (post-only)

### Channel permission model for verification

**New channel flag: `postOnly`** (boolean, stored as a tag on the channel's Nostr event)
- When true: users can create messages but cannot read message history or see other users' messages
- Only users with `manage_messages` permission (mods/admins) can read the full channel
- This is critical for verification channels -- submissions may contain sensitive info

**Implementation of `postOnly`:**
```dart
// In the channel access check logic
ChannelAccess getChannelAccess(Channel channel, ServerMembership membership) {
  if (channel.postOnly) {
    if (membership.hasPermission(Permission.manageMessages)) {
      return ChannelAccess.full; // mods see everything
    } else {
      return ChannelAccess.postOnly; // regular users can post but not read
    }
  }
  return ChannelAccess.full;
}
```

**Channel view behavior for `postOnly`:**
- No message history rendered
- Input box is visible with placeholder: "Submit your verification here..."
- User sees a notice: "Your submission is only visible to moderators"
- After posting, user sees their own message with a "Submitted" confirmation

### Drift schema additions

The `servers` Drift table already stores server metadata synced from Nostr events. The `serverType` (string) and `ageRestricted` (boolean) fields are parsed from the server's replaceable event tags and stored as columns.

The `channels` Drift table gains a `postOnly` boolean column, also synced from the channel's Nostr event tags.

### Join flow for age-restricted servers

1. User clicks invite link -- resolve preview shows server info + age restriction badge
2. Age gate confirmation dialog appears
3. User confirms -- membership event published, local `ServerMembership` row created with base role
4. User lands in server but can only see #rules and #verification-submit
5. User posts in #verification-submit
6. Mod reviews -- grants `Verified` role via member management UI
7. User now sees all channels

### What admins see in settings

In the server settings overlay, if `ageRestricted`:
```
AGE RESTRICTION
  This server requires age verification.

  Verification channel: #verification-submit
  Pending verifications: 3
  [View pending ->]

  Verified role: @Verified (12 members)
```

The "View pending" link goes to the verification channel where mods can read submissions and grant roles inline.

---

## Part 7: Reputation Scoring -- Backend Only

### Why it is hidden from users

Reputation systems have a mixed track record. Research into major platforms shows:

- **What works:** Multi-signal fusion (email spam filtering combining reputation + content + DKIM = 99.9% accuracy), graduated response instead of binary bans (Xbox Live), per-signal caps to prevent brigading.
- **What fails:** Single-signal systems (Reddit karma is decorative), visible scores that get gamed (Stack Overflow rep farming), systems without human oversight (SpamAssassin needed retraining every 6 months as spammers adapted).
- **The honest assessment of our scorer:** "Is this person my friend?" catches 80% of what you need. "Have they been reported N times?" catches most of the rest. The weighted reputation score fills the gap between those two -- real but narrow. It adds value as one signal among many, but does not justify exposing complex UI to users.

### Design
- Reputation scoring runs silently as one of the 6 stages in `ContentSafetyService`
- Enabled/disabled by the protection level preset (Standard = on, Relaxed = off)
- Threshold and sensitivity are fixed at sensible defaults in code (threshold: 30, sensitivity: moderate)
- These values change only when you push a new release -- no UI to configure them
- No user ever sees a reputation score or needs to understand how it works

### Scoring logic

**File:** `lib/services/reputation_scorer.dart`
- Base score: 100 for every pubkey
- Penalties: hides (-5 per, capped), reports (-10 per, capped), bans (-25 per, capped)
- Bonuses: friend relationship (+20), mutual friends (+5 per, capped)
- Per-signal caps prevent brigading (no single signal type can tank a score below the floor)
- Sensitivity multiplier adjusts how aggressively penalties are applied (moderate = 1.0x)

The scorer reads from the local Drift database (contacts, reports, bans) and computes scores on demand. No network calls. No central authority.

---

## Part 8: Shared Hash Network

### How it works

When a user hides a message containing images, the client:
1. Computes dHash of each image (9x8 grayscale resize via the `image` Dart package, row-wise gradient comparison, 64-bit hex output)
2. Publishes a NIP-56 Kind 1984 report event to connected relays with `["x", "<hash>"]` tags
3. Other clients subscribed to report events receive these hashes
4. Each client applies trust-weighted confidence scoring to decide whether to block the hash locally

### Trust weighting
- Report from a friend: weight 1.0
- Report from a friend-of-friend: weight 0.5
- Report from a stranger: weight 0.1
- Confidence = sum of weighted reports for a given hash
- Hide threshold: confidence >= 3.0 (default, hardcoded)

### Implementation

**File:** `lib/services/shared_hash_service.dart`
- Subscribes to Kind 1984 events from relays
- Parses `["x"]` tags to extract image hashes
- Looks up reporter pubkey in local contacts to determine trust weight
- Upserts into `content_hashes` Drift table with updated confidence scores
- Publishes report events when the local user hides content

**Drift table: `content_hashes`**
```dart
class ContentHashes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get hashValue => text()();
  TextColumn get hashType => text()();       // "dhash"
  RealColumn get confidence => real().withDefault(const Constant(0.0))();
  BoolColumn get allowlisted => boolean().withDefault(const Constant(false))();
  TextColumn get reportedBy => text().nullable()(); // JSON array of pubkeys
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [{hashValue, hashType}];
}
```

### Promotion to CSAM table
When a `content_hashes` entry reaches high confidence AND was reported with a severe category ("illegal", "csam"), it is automatically copied into `csam_hash_entries`. Once promoted, it becomes non-overridable and non-allowlistable.

---

## Part 9: Report to Authorities

### The problem
A user sees CSAM or a credible threat. They can hide it, which protects other users on the network. But there is no path from "I saw something illegal" to "law enforcement knows about it." Most people will not know where to report or what information to include.

### The other problem: petty reporting
People rage-report all the time. Someone says something rude, the other person clicks "report to authorities" out of spite. If generating a police report is as easy as hiding a message, it WILL be abused. This wastes law enforcement resources, could ruin someone's life over chat drama, and makes real reports less credible when they do come through.

### Design: deliberate, separated, serious

**Not automated. Not casual. Not in the hide menu.**

Reporting to authorities is a legal action. Hiding a message is moderation. They are completely separate flows. The report option is only accessible from the hidden messages review list in safety settings -- meaning the user has already hidden the message, left the chat, navigated to settings, and is now making a deliberate choice.

### The flow (intentionally multi-step)

**Step 1: User hides message** (normal flow, easy, quick -- this is just moderation)

**Step 2: User navigates to Safety Settings -> Hidden Messages**
Next to each hidden message's "Unhide" button, there is a small, non-prominent "Report to authorities" text link. Not a button, not colored, not attention-grabbing.

**Step 3: Confirmation dialog**
```
Report to Law Enforcement

This generates a formal report containing message metadata and
identifiers that law enforcement can use to investigate.

This is for ILLEGAL ACTIVITY only:
  ( ) Child sexual abuse material (CSAM)
  ( ) Credible threats of violence
  ( ) Terrorism
  ( ) Other illegal activity

This is NOT for:
  - Someone being rude or offensive
  - Spam or scam messages
  - Content you personally disagree with
  - Server drama or personal disputes

Filing a false police report is a crime in most jurisdictions.
```

User must select a category to proceed.

**Step 4: Final confirmation**
```
You are about to generate a report for law enforcement regarding:
  [Category selected]

This report will contain message metadata and Nostr identifiers.
You are responsible for submitting it to the appropriate authority.

  [Cancel]  [Generate Report]
```

**Step 5: Report generated**
A downloadable plain text file is produced containing:
- Message content (text only)
- Sender's Nostr pubkey (hex and npub)
- Timestamp (UTC)
- Nostr event ID (law enforcement can use this to retrieve original content from relays)
- Relay URLs where the event was seen
- Server name and channel (if applicable)
- Image metadata (filenames, sizes, dHash values -- NOT the actual images)
- The reporter's own pubkey (so law enforcement can contact them if needed)
- Category of report selected

Format: plain text, clearly labeled with headers. Something a non-technical person could hand to a police officer.

**Step 6: Authority links shown**
- **CSAM:** NCMEC CyberTipline -- https://report.cybertip.org
- **Terrorism:** FBI IC3 -- https://ic3.gov
- **UK:** Internet Watch Foundation -- https://iwf.org.uk
- **EU:** Europol -- https://europol.europa.eu/report-a-crime
- **General:** guidance on finding local law enforcement contacts

The screen explains: "Law enforcement can use the Nostr event ID in this report to retrieve the original content from relays with proper legal authority. You do not need to provide the original images."

### Implementation

**File:** `lib/services/authority_report_generator.dart`
- `generateReport(Message message, String category)` -- builds the plain text report from message metadata, Nostr event data, and relay information stored in the local Drift database
- Returns a `String` that gets written to a file via `path_provider` and shared via the platform's share sheet or saved to the user's chosen location

**File:** `lib/screens/settings/safety_screen.dart`
- The hidden messages list includes the "Report to authorities" text link per entry
- Tapping it opens a multi-step dialog (steps 3-6 above) built as a stateful widget

### Why this many steps
Every step is a chance for a petty reporter to bail. Someone who has genuinely seen CSAM will click through all of it because the stakes are real. Someone who is mad about a chat argument drops off when they read "Filing a false police report is a crime" or when they have to categorize what they saw and realize "someone called me an idiot" is not on the list.

### What the app does NOT do
- No automatic reporting to any authority -- ever
- No easy/quick path to generate a report -- deliberate friction by design
- No image retention for evidence -- images are not stored after hiding
- No tracking of who reported what to authorities (the NIP-56 report to the Nostr network still happens, but that is separate)
- No evidence chain custody -- the app generates a report, the user decides what to do with it
- No retention of the report file -- it is generated on demand and saved/shared, not stored in the database
- No "report to authorities" option in the message action menu -- only accessible from safety settings hidden messages list

### Why not retain images for evidence?
Possessing CSAM, even temporarily for reporting purposes, is legally complicated and varies by jurisdiction. Law enforcement has the tools and legal authority to retrieve content from Nostr relays using the event ID. Keep the user legally clean -- give them identifiers, not material.

---

## Content Safety Pipeline -- 6 Stages

`lib/services/content_safety_service.dart` runs these stages in order for every incoming message. The pipeline short-circuits on the first match.

| Stage | Check | Source | Overridable | Hide Reason |
|-------|-------|--------|-------------|-------------|
| 1 | CSAM hash match | `csam_hash_entries` Drift table | **No** | `csam_match` |
| 2 | NSFW model detection | ONNX two-stage pipeline via FFI | Yes (unhide) | `auto:nsfw` |
| 3 | Unknown sender filter | Contact relationship check | Yes (accept DM) | `unknown_sender` |
| 4 | Report threshold | Count of NIP-56 reports against sender | Yes (unhide) | `report_threshold` |
| 5 | Reputation score | `lib/services/reputation_scorer.dart` | Yes (unhide) | `low_reputation` |
| 6 | Image hash (shared network) | `content_hashes` Drift table | Yes (unhide + allowlist) | `hash_match` |

Text filters (links, phone numbers, caps, spam chars) run as a sub-step within stage 3 for unknown senders only.

### Hidden message storage
Messages that fail any stage have their `hiddenAt` and `hiddenReason` columns set in the `messages` Drift table. The message row is not deleted -- it remains in the database but is not rendered in the message list widget. The hidden messages review list in safety settings queries for all messages where `hiddenAt IS NOT NULL`.

---

## Implementation Order

### Phase 1: Foundation (do first)
1. **Simplified safety UI** -- protection level dropdown in `safety_screen.dart`, strip down to two choices
2. **CSAM hash table + checking** -- Drift table, integration with `content_safety_service.dart`
3. **Synchronous image checking for non-friends** -- close the render-then-hide window

### Phase 2: Server Tooling
4. **Server type field + templates** -- Nostr event tags, channel/role scaffolding
5. **Server creation wizard** -- multi-step UI in `add_server_dialog.dart`
6. **Age-restricted server flag** -- age gate dialog on join

### Phase 3: Verification System
7. **Post-only channel type** -- channel flag, visibility logic, widget behavior
8. **Verification flow** -- verification-submit channel, mod review, role granting
9. **Admin verification dashboard** -- pending count, inline role granting in server settings overlay

### Phase 4: Advanced Protection
10. **NSFW detection model** -- ONNX FFI integration, two-stage pipeline in `noise_processor.dart`
11. **Open hash list integration** -- StopNCII API, community lists, auto-promotion from shared network
12. **Report to authorities flow** -- `authority_report_generator.dart`, multi-step dialog in safety settings

---

## What We Are NOT Doing
- No real ID or birthdate collection -- decentralized app, can not verify, do not want the data
- No automated grooming pattern detection -- too many false positives, too surveillance-like
- No automated reporting to authorities -- user always decides
- No image retention for evidence -- metadata and identifiers only, law enforcement retrieves content themselves
- No blocking all DMs by default -- kills the social experience
- No server-side content analysis -- all processing is on-device, privacy matters in a Nostr app
- No exposed reputation scores or formulas to regular users
- No keyword list as a primary defense -- too easy to bypass
- No server-level reputation or "rotten server" blacklists -- protection is per-user trust graph, not centralized judgment
- No cloud APIs or third-party scanning services -- everything runs locally
