# Content Safety Overhaul — Complete Plan

## Design Philosophy

**Seatbelt, not a locked door.** You can't stop a determined kid from joining an "adult" server — every parental control in history has been bypassed by 12-year-olds. The goal is to ensure that when users are *anywhere* in the app, the worst content doesn't reach them unsolicited. Passive protection that's always on, not gatekeeping they can disable.

**Two audiences:**
1. **Regular users** — see almost nothing. A protection level toggle and a hidden-messages review list. Done.
2. **Server admins** — guided onboarding wizard that sets safe defaults based on server type. Age-gating tools for 18+ servers.

There is no instance admin panel. Advanced tuning (reputation thresholds, shared hash config, CSAM list updates, NSFW model thresholds) are hardcoded defaults shipped in the codebase. They change when you push a release tag and clients update. This keeps the system consistent across all users and avoids misconfiguration.

**Kids are not stupid.** They will find ways around age gates and content filters to get into servers where their friends are. Every parental control ever built has been defeated by 12-year-olds. The system doesn't try to prevent this. Instead, it ensures that *wherever* a user ends up — even in an "adult" server they bypassed verification for — the worst unsolicited content (CSAM, predatory DMs, spam from strangers) is still caught by passive protections that can't be turned off.

---

## Part 0: Day-One Cold Start Problem

### The vulnerability
Day one, the shared hash network is empty, the CSAM table is empty, and every user is unprotected by hashing until *someone* hides something first. The first users to encounter harmful content ARE the protection for everyone after them. Someone has to see it first.

### Defenses that work without data (day-one ready)
These require zero hash data to function — they work the moment the app is installed:

1. **NSFW detection model** — The ONNX classifier ships with the app. It's a pre-trained model, not a database. It classifies images locally on day one with zero data needed. This is the strongest day-one protection for explicit content.
2. **Unknown sender holding** — No data needed. Messages from non-friends are held/filtered by default in Standard mode. Pure policy, works immediately.
3. **Synchronous image checking** — Even without hashes to match against, the infrastructure ensures non-friend images go through the check pipeline before rendering. When hashes DO exist, they're caught before display.
4. **Spam preset filters** — Block links, phone numbers, ALL CAPS, repeated characters. Pattern matching, no database needed.

### Seeding the hash database before launch
Before the first public release, manually populate the hash table:
- Run the app against collections of known-bad image hashes from open sources (StopNCII, community lists)
- Use your own testing to generate perceptual hashes from test images
- The table doesn't start at zero — it starts at whatever you can seed before shipping

### Making hiding feel impactful
The first reporters are the most valuable users in the network. Hiding harmful content should feel like a contribution, not just housekeeping:
- **Instant feedback on hide:** "This image's fingerprint has been shared with the network to protect other users."
- **Quiet acknowledgment:** A subtle note in safety settings: "You've helped protect the network from N harmful images" — not gamified, no leaderboards, no badges. Just recognition that the action mattered.
- The goal is to make users feel like hiding is worth doing — not just for their own feed, but for everyone.

### The compounding effect
The hash network is a compounding defense. Day one it's thin. By week two, early adopters have seeded it. By month three, the most common harmful images are caught before anyone new sees them. The longer the network runs, the stronger it gets. The day-one gap is real but temporary, and the other filters cover it.

---

## Part 0b: Rotten Servers and Bad Actors

### The reality of decentralization
Anyone can run a server. That includes terrorists, pedophiles, and crime organizations. In a federated system, you cannot prevent bad servers from existing. Attempting to maintain a "bad server blacklist" is centralized moderation with extra steps — someone has to decide which servers are bad, and that someone becomes a single point of control and failure.

### Why the trust graph naturally isolates bad actors

The shared hash network operates at the **individual pubkey level**, not the server level. This is critical:

- **Bad actors don't end up in good users' friend lists.** The trust weighting means their reports carry almost no weight (0.1 per stranger). A cluster of criminals friending each other and coordinating reports only affects... each other.
- **Poisoning the hash network is impractical.** To affect a stranger's client, you need 30+ coordinated Nostr accounts all reporting the same hash. Even then, the user can unhide false positives, which allowlists the hash permanently.
- **The network is defensive, not authoritative.** Each client decides for itself what to block based on its *own* trust graph. There is no central authority a rotten server can manipulate.
- **Your trust graph IS your protection.** If you have good friends, you're well protected. The system reflects the quality of your social network, not a global moderation decision.

### What you can do
- **Users are protected passively** regardless of what server they're in — CSAM checking, NSFW detection, unknown sender filtering, image hashing all run per-client
- **Server discovery is opt-in** — rotten servers won't mark themselves discoverable
- **The report-to-authorities flow** gives users a clear path when they encounter illegal activity

### What you deliberately don't do
- No server-level reputation or blacklists
- No centralized "bad server" registry
- No attempt to shut down or block servers — that's centralized thinking
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
- **Strip images and links from the preview.** The user sees "Someone wants to message you" with the text content only — no inline images, no clickable links.
- **Images are held through the safety pipeline** before the conversation is even accepted. If they match CSAM/blocked hashes or the NSFW model flags them, the conversation request is auto-hidden before the user ever sees it.
- **If the user accepts the conversation**, images and links render normally going forward (they've chosen to engage with this person).
- **First message from stranger with ONLY images and no text** shows: "This person sent you an image. Accept the conversation to view it." — never auto-displays stranger images in request previews.

This means a predator sending unsolicited images to strangers hits a wall: the image never renders unless the target explicitly accepts the conversation, and if the image matches any safety filter, the request is silently hidden.

---

## Part 1: Simplified User Safety Settings

### Current Problem
The safety settings page exposes 15+ toggles, number inputs, sensitivity dropdowns, and scoring formulas. No regular user should see any of this. The reputation system explanation alone is a paragraph of text about penalty caps and signal weights.

### New Design

**The user sees:**
```
CONTENT PROTECTION
  [Standard ▾]     ← dropdown: Standard / Relaxed

  Standard: Blocks harmful images, filters spam, holds messages
            from unknown senders. Recommended for most users.

  Relaxed:  Image protection stays on. Spam filtering and
            unknown sender holds are turned off.

HIDDEN MESSAGES
  [list of auto-hidden messages with Unhide buttons]
```

That's it. Two choices. One list.

### What each mode maps to internally

| Setting | Standard | Relaxed |
|---------|----------|---------|
| `safety_image_hash_enabled` | true | true |
| `safety_shared_hashes_enabled` | true | true |
| `safety_publish_hashes` | true | true |
| `safety_hide_unknown_senders` | true | false |
| `safety_block_links` | true | false |
| `safety_block_phone_numbers` | true | false |
| `safety_block_all_caps` | true | false |
| `safety_block_spam_chars` | true | false |
| `safety_reputation_enabled` | true | false |
| `safety_reputation_threshold` | 30 | 30 |
| `safety_reputation_sensitivity` | moderate | moderate |
| `safety_report_threshold` | 3 | 0 |
| CSAM hash list checking | **always on** | **always on** |
| NSFW image detection | true | true |

**Key:** Image protection and CSAM list are always on in both modes. You cannot disable them. The CSAM check has no toggle — it's hardcoded.

### What happens to the keyword filter
The user-facing keyword list goes away from the main settings. The preset checks (block links, block phones, block caps, block spam) are toggled automatically by the protection mode. The custom word list stays in code as a hardcoded default that ships with updates — no user-facing editor.

### Implementation

**Files:**
- `app/models/local_config.rb` — add `safety_protection_level` column (string: "standard" / "relaxed"), add `apply_protection_level!` method that sets all the individual toggles
- `app/views/settings/safety.html.erb` — strip down to dropdown + hidden messages list
- `app/controllers/settings_controller.rb` — `update_safety` takes only `safety_protection_level` param, calls `apply_protection_level!`

---

## Part 2: Harmful Content Hash Database

### Why it works for a decentralized app
The hash database sits locally, like a virus signature database. Images are compared on the user's own machine. Nothing leaves the device. No API call, no cloud service, no third party sees the content. It's the user's own client choosing not to display known illegal material.

### Hash sources (realistic, no licensing barriers)

**Primary: The shared hash network (already being built)**
When any Inferno user hides harmful content, those image hashes propagate through Nostr relays via NIP-56 reports with `["x"]` tags. Over time this becomes a crowdsourced blocklist. Trust-weighted confidence scoring prevents abuse. This is the main mechanism — it grows organically with the user base and requires zero external dependencies.

**Secondary: Open/public hash lists**
Some organizations publish hash lists without formal applications:
- **StopNCII.org** — public API for non-consensual intimate image hashes
- **Open-source community-curated lists** — projects that maintain freely available hash databases
- Any future open lists can be added by shipping a new list source in a release

**Future-proofed: Provider lists (if ever obtained)**
The table is designed to accept hashes from any source. If you ever establish a relationship with NCMEC, IWF, or Project VIC, their hashes slot right in. But the system doesn't depend on this — it works without it.

**Why not NCMEC/IWF right now?**
These providers license hash databases to *organizations*, not individual end users. They require applications, legal agreements, compliance audits, and reporting obligations. A decentralized client-side app where each user runs their own instance doesn't fit their model. Designing around this dependency would block the entire safety system on a bureaucratic process that may never complete.

### Implementation approach

**New model: `CsamHashEntry`** (separate from `ContentHash` — this is a reference database, not user-generated)
```ruby
create_table :csam_hash_entries do |t|
  t.string :hash_value, null: false
  t.string :hash_type, null: false  # "md5", "sha1", "phash", "dhash"
  t.string :list_source              # "shared_network", "stopncii", "community", "custom"
  t.datetime :added_at
  t.index [:hash_value, :hash_type], unique: true
end
```

**Feeding from the shared hash network:**
- When a shared `ContentHash` reaches high confidence (many trusted reporters) AND was reported with a severe reason (e.g., the NIP-56 report content is "illegal" or "csam"), it gets promoted into `CsamHashEntry` automatically
- This means the shared network isn't just blocking future matches via `ContentHash` — the worst content gets elevated to the permanent, non-overridable CSAM table
- Promotion threshold is hardcoded (e.g., confidence >= 5.0 with at least 2 friend reporters or 15+ strangers)

**Feeding from open lists:**
- `UpdateCsamHashListJob` — periodic job that fetches from configured open list URLs and upserts entries
- List URLs are hardcoded in the app and updated via release tags
- Ships with StopNCII integration if their API is accessible; other lists added as they become available

**Checking flow:**
1. Image arrives (via message creation or relay subscription)
2. **Before rendering** (synchronous for non-friend senders, async for friends): compute perceptual hash
3. Check against `CsamHashEntry` table — if match, the message is **permanently hidden** with reason `"csam_match"`
4. CSAM-matched messages cannot be unhidden via the normal UI. No allowlisting. No appeals through the settings page.
5. The hidden message entry shows "This message was blocked by automated safety systems" with no preview of the content

**Non-negotiable behaviors:**
- Cannot be disabled by any user setting or protection level
- CSAM-matched `ContentHash` entries cannot be allowlisted (override in `ContentHash#allowlist!`)
- No content preview in the hidden messages list for CSAM matches
- Matched hashes are automatically published to the shared hash network to protect other users

---

## Part 3: Synchronous Image Checking for Non-Friends

### Current Problem
Image hashing happens in `StoreImageHashesJob` (async, after message creation). The image renders in chat, then gets hidden moments later. For harmful content from strangers, that window is the entire problem.

### New Flow

**For messages from non-friends (no Contact record or contact not accepted):**
1. Message arrives with image attachments
2. `ContentSafetyFilter#check!` runs (already happens via `ContentSafetyCheckJob`)
3. **Change:** Before the message is broadcast to the chat channel, run image hash check synchronously
4. If hash matches CSAM list or existing blocked hash → hide immediately, never broadcast
5. If hash doesn't match → broadcast normally, store hash async for future matching

**For messages from friends:**
- Keep current async flow (trust but verify in background)
- Friends' images still get hashed for the database but aren't held

### Implementation

**File:** `app/models/message.rb`
- Modify `run_content_safety_check` — for non-friend senders, run `ContentSafetyCheckJob.perform_now` instead of `perform_later`
- Or better: inline the critical checks (CSAM + image hash) in `after_create_commit` before the ActionCable broadcast

**File:** `app/services/content_safety_filter.rb`
- Add `image_csam_match?` check that runs before `image_hash_match?`
- This check hits `CsamHashEntry` table specifically
- Runs synchronously when called from the inline path

**File:** `app/channels/channel_chat_channel.rb` (or wherever broadcast happens)
- Message broadcast should check `message.hidden?` before sending to clients

---

## Part 4: Local NSFW Detection

### Approach
Use a lightweight on-device model to flag explicit images before display. No cloud API, keeps everything private.

**Options (in order of preference):**
1. **ONNX Runtime + open NSFW classifier** — Ruby has `onnxruntime` gem, can run a small model (~10MB) locally. Classify images as SFW/NSFW with a confidence score.
2. **ImageMagick skin-tone heuristic** — much simpler, less accurate. Detect percentage of skin-tone pixels. High false positive rate but zero dependencies.
3. **Shell out to Python script** — if the user has Python installed, use a proper ML model. Less portable.

### Recommendation
Option 1 (ONNX). It's the right balance of accuracy and portability. The model runs in-process, no external service, works offline.

### Implementation

**New service:** `app/services/nsfw_detector.rb`
```ruby
class NsfwDetector
  MODEL_PATH = Rails.root.join("lib/models/nsfw_classifier.onnx")

  def self.available?
    defined?(OnnxRuntime) && File.exist?(MODEL_PATH)
  end

  # Returns { safe: 0.92, explicit: 0.05, suggestive: 0.03 }
  def self.classify(image_path)
    # Load model, preprocess image, run inference
  end

  def self.explicit?(image_path, threshold: 0.7)
    return false unless available?
    result = classify(image_path)
    result[:explicit] >= threshold
  end
end
```

**Integration with ContentSafetyFilter:**
- New filter step between keyword and image hash: `nsfw_image_match?`
- For non-friend senders: runs synchronously (same as CSAM check)
- For friend senders: runs async
- Auto-hides with reason `"auto:nsfw"`
- NSFW-hidden messages CAN be unhidden (unlike CSAM) — they're inappropriate, not illegal

**Server-level interaction:**
- Servers marked as 18+ skip NSFW filtering for their channels (the content is expected)
- DMs always get NSFW checked regardless of server context
- NSFW detection respects the user's protection level (Standard = on, Relaxed = on, both modes)

---

## Part 5: Server Admin Onboarding Wizard

### Current Problem
Server creation is: pick a name, upload an icon, done. Admin gets an empty server with a "general" channel and has to figure out roles, safety, channels, and invites on their own. No guidance on content policies.

### New Server Creation Flow

**Step 1: Name & Icon** (existing, keep as-is)

**Step 2: Server Type** (NEW)
```
What kind of server is this?

  ○ Community        Public-facing community. Open invites, discoverable.
  ○ Friends & Family Private group. Invite-only, not discoverable.
  ○ Gaming           Game-focused. Voice channels, LFG, screenshots.
  ○ Work / Team      Professional. Projects, standups, announcements.
  ○ 18+ Community    Age-restricted. Requires member verification.
```

**Step 3: Channels** (NEW — template based on type)

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

  → Invite members: [copy invite link]
  → Customize further in Server Settings
```

### What the server type auto-configures

| Setting | Community | Friends | Gaming | Work | 18+ |
|---------|-----------|---------|--------|------|-----|
| Discoverable | true | false | false | false | false |
| Default roles | Admin, Mod, Member | Admin, Member | Admin, Mod, Member | Admin, Manager, Member | Admin, Mod, Verified, Member |
| Welcome message | on | on | on | on | on (with age notice) |
| `age_restricted` | false | false | false | false | **true** |
| Verification required | no | no | no | no | **yes** |
| NSFW filter in channels | on | on | on | on | **off** (expected content) |

### Implementation

**Files:**
- `app/views/servers/new.html.erb` — multi-step wizard (Stimulus controller for step navigation)
- `app/controllers/servers_controller.rb` — `create` accepts `server_type` param
- `app/models/server.rb` — `apply_server_template!(type)` method that creates channels, roles, rules channel, sets flags
- `app/javascript/controllers/server_wizard_controller.js` — NEW, handles step transitions and channel template editing
- Migration: add `server_type` and `age_restricted` columns to `servers`

---

## Part 6: Age-Restricted Servers

### The honest reality
An "Are you 18?" checkbox does nothing protective. A determined kid clicks yes. But it serves two purposes:
1. Establishes intent — the admin asked, the user affirmed
2. Creates a friction point that stops casual/accidental exposure

The real protection comes from **mod-verified gating**: a human reviews the request before granting access.

### Two-tier system

**Tier 1: Age Gate (automatic)**
- Server is marked `age_restricted: true`
- When a user tries to join (via invite or discovery), they see a confirmation:
  ```
  This server is age-restricted (18+)

  By continuing, you confirm that you are 18 years of age or older.

  [Cancel]  [I am 18 or older]
  ```
- Clicking confirm is logged (timestamp + user ID)
- User joins with the `@everyone` role (restricted — can only see `#verification-submit`)

**Tier 2: Mod Verification (gated access)**
- After joining, user lands in `#verification-submit` — a special channel where:
  - Users CAN post (submit their verification)
  - Users CANNOT see message history (other people's submissions)
  - Only mods can read the full history
- The admin defines what "verification" means for their server (selfie with username, ID with birthdate redacted, just a conversation — up to them)
- A mod grants the `Verified` role → user gains access to all regular channels
- Until verified, the user can only see `#rules` (read-only) and `#verification-submit` (post-only)

### Channel permission model for verification

**New channel flag: `post_only`** (boolean)
- When true: users can create messages but cannot read message history or see other users' messages
- Only users with `manage_messages` permission (mods/admins) can read the full channel
- This is critical for verification channels — submissions may contain sensitive info

**Implementation of `post_only`:**
```ruby
# channel.rb
def visible_to?(user)
  membership = user.server_memberships.find_by(server: server)
  return false unless membership

  if post_only?
    if membership.has_permission?(:manage_messages)
      :full  # mods see everything
    else
      :post_only  # regular users can post but not read
    end
  elsif encrypted?
    # ... existing encrypted channel logic
  else
    :full
  end
end
```

**Channel view behavior for `post_only`:**
- No message history rendered
- Input box is visible with placeholder: "Submit your verification here..."
- User sees a notice: "Your submission is only visible to moderators"
- After posting, user sees their own message with a "Submitted" confirmation

### New database columns

```ruby
# servers
add_column :servers, :server_type, :string, default: "community"
add_column :servers, :age_restricted, :boolean, default: false
add_column :servers, :age_gate_confirmed_at, :json, default: {}
# ^ stores { user_id => timestamp } for audit trail

# channels
add_column :channels, :post_only, :boolean, default: false
```

### Join flow for age-restricted servers

1. User clicks invite link → resolve preview shows server info + age restriction badge
2. Age gate confirmation dialog appears
3. User confirms → `ServerMembership` created with only `@everyone` role
4. User lands in server but can only see `#rules` and `#verification-submit`
5. User posts in `#verification-submit`
6. Mod reviews → grants `Verified` role via member management
7. User now sees all channels

### What admins see in settings

In the server settings overview, if `age_restricted`:
```
AGE RESTRICTION
  This server requires age verification.

  Verification channel: #verification-submit
  Pending verifications: 3
  [View pending →]

  Verified role: @Verified (12 members)
```

The "View pending" link goes to the verification channel where mods can read submissions and grant roles inline.

---

## Part 7: Reputation Scoring — Backend Only

### Why it's hidden from users

Reputation systems have a mixed track record. Research into major platforms shows:

- **What works:** Multi-signal fusion (email spam filtering combining reputation + content + DKIM = 99.9% accuracy), graduated response instead of binary bans (Xbox Live), per-signal caps to prevent brigading.
- **What fails:** Single-signal systems (Reddit karma is decorative), visible scores that get gamed (Stack Overflow rep farming), systems without human oversight (SpamAssassin needed retraining every 6 months as spammers adapted).
- **The honest assessment of our scorer:** "Is this person my friend?" catches 80% of what you need. "Have they been reported N times?" catches most of the rest. The weighted reputation score fills the gap between those two — real but narrow. It adds value as one signal among many, but doesn't justify exposing complex UI to users.

### Current State
Reputation scoring is exposed in user settings with threshold number, sensitivity dropdown, and a paragraph explaining the formula. This goes away from user-facing settings.

### New State
- Reputation scoring runs silently as one of many signals in `ContentSafetyFilter`
- Enabled/disabled by the protection level preset (Standard = on, Relaxed = off)
- Threshold and sensitivity are fixed at sensible defaults in code (threshold: 30, sensitivity: moderate)
- These values change only when you push a new release — no UI to configure them
- No user ever sees a reputation score or needs to understand how it works

### No changes to the scoring logic itself
The `ReputationScorer` service stays as-is. The per-signal caps, the friend bonus, the sensitivity multipliers — all good design that works in the backend. It just doesn't need a UI.

---

## Migration Summary

```ruby
class ContentSafetyOverhaul < ActiveRecord::Migration[8.1]
  def change
    # User protection level (replaces all individual safety toggles for users)
    add_column :instance_configs, :safety_protection_level, :string, default: "standard"

    # CSAM hash list
    create_table :csam_hash_entries do |t|
      t.string :hash_value, null: false
      t.string :hash_type, null: false
      t.string :list_source
      t.datetime :added_at
      t.timestamps
      t.index [:hash_value, :hash_type], unique: true
      t.index :list_source
    end

    # Server onboarding
    add_column :servers, :server_type, :string, default: "community"
    add_column :servers, :age_restricted, :boolean, default: false

    # Post-only channels (for verification)
    add_column :channels, :post_only, :boolean, default: false
  end
end
```

---

## Implementation Order

### Phase 1: Foundation (do first)
1. **Simplified safety UI** — protection level dropdown, strip the settings page
2. **CSAM hash table + checking** — model, migration, integration with ContentSafetyFilter
3. **Synchronous image checking for non-friends** — close the render-then-hide window

### Phase 2: Server Tooling
4. **Server type column + templates** — migration, model method, channel/role scaffolding
5. **Server creation wizard** — multi-step UI with type selection and channel templates
6. **Age-restricted server flag** — age gate dialog on join

### Phase 3: Verification System
7. **Post-only channel type** — channel flag, visibility logic, view behavior
8. **Verification flow** — verification-submit channel, mod review, role granting
9. **Admin verification dashboard** — pending count, inline role granting

### Phase 4: Advanced Protection
10. **NSFW detection model** — ONNX integration, NsfwDetector service
11. **Open hash list integration** — StopNCII API, community lists, auto-promotion from shared network
12. **Report to authorities flow** — report generation, authority links

---

## Part 8: Report to Authorities

### The problem
A user sees CSAM or a credible threat. They can hide it, which protects other users on the network. But there's no path from "I saw something illegal" to "law enforcement knows about it." Most people won't know where to report or what information to include.

### The other problem: petty reporting
People rage-report all the time. Someone says something rude, the other person clicks "report to authorities" out of spite. If generating a police report is as easy as hiding a message, it WILL be abused. This wastes law enforcement resources, could ruin someone's life over chat drama, and makes real reports less credible when they do come through.

### Design: deliberate, separated, serious

**Not automated. Not casual. Not in the hide menu.**

Reporting to authorities is a legal action. Hiding a message is moderation. They are completely separate flows. The report option is only accessible from the hidden messages review list in safety settings — meaning the user has already hidden the message, left the chat, navigated to settings, and is now making a deliberate choice.

### The flow (intentionally multi-step)

**Step 1: User hides message** (normal flow, easy, quick — this is just moderation)

**Step 2: User navigates to Safety Settings → Hidden Messages**
Next to each hidden message's "Unhide" button, there's a small, non-prominent "Report to authorities" text link. Not a button, not colored, not attention-grabbing.

**Step 3: Confirmation page**
```
Report to Law Enforcement

This generates a formal report containing message metadata and
identifiers that law enforcement can use to investigate.

This is for ILLEGAL ACTIVITY only:
  ○ Child sexual abuse material (CSAM)
  ○ Credible threats of violence
  ○ Terrorism
  ○ Other illegal activity

This is NOT for:
  · Someone being rude or offensive
  · Spam or scam messages
  · Content you personally disagree with
  · Server drama or personal disputes

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
A downloadable file is produced containing:
- Message content (text only)
- Sender's Nostr pubkey
- Timestamp (UTC)
- Nostr event ID (law enforcement can use this to retrieve original content from relays)
- Relay URLs where the event was seen
- Server name and channel (if applicable)
- Attachment metadata from `hidden_attachment_records` (filenames, sizes, checksums — NOT the actual images)
- The reporter's own pubkey (so law enforcement can contact them if needed)
- Category of report selected

Format: plain text, clearly labeled with headers. Something a non-technical person could hand to a police officer.

**Step 6: Authority links shown**
- **CSAM:** NCMEC CyberTipline — https://report.cybertip.org
- **Terrorism:** FBI IC3 — https://ic3.gov
- **UK:** Internet Watch Foundation — https://iwf.org.uk
- **EU:** Europol — https://europol.europa.eu/report-a-crime
- **General:** guidance on finding local law enforcement contacts

The page explains: "Law enforcement can use the Nostr event ID in this report to retrieve the original content from relays with proper legal authority. You do not need to provide the original images."

### Why this many steps
Every step is a chance for a petty reporter to bail. Someone who's genuinely seen CSAM will click through all of it because the stakes are real. Someone who's mad about a chat argument drops off when they read "Filing a false police report is a crime" or when they have to categorize what they saw and realize "someone called me an idiot" isn't on the list.

### What the app does NOT do
- No automatic reporting to any authority — ever
- No easy/quick path to generate a report — deliberate friction by design
- No image retention for evidence — attachments are purged on hide as usual
- No tracking of who reported what to authorities (the NIP-56 report to the Nostr network still happens, but that's separate)
- No evidence chain custody — the app generates a report, the user decides what to do with it
- No retention of the report file — it's generated on demand and downloaded, not stored
- No "report to authorities" option in the message action menu — only accessible from safety settings hidden messages list

### Why not retain images for evidence?
Possessing CSAM, even temporarily for reporting purposes, is legally complicated and varies by jurisdiction. Law enforcement has the tools and legal authority to retrieve content from Nostr relays using the event ID. Keep the user legally clean — give them identifiers, not material.

### Implementation

**Files:**
- `app/controllers/settings_controller.rb` — new `authority_report` page and `generate_authority_report` action
- `app/services/authority_report_generator.rb` — NEW, formats the report as plain text
- `app/views/settings/authority_report.html.erb` — NEW, the multi-step confirmation flow
- `config/routes.rb` — routes for the report flow (GET for the page, POST to generate)

---

## What We're NOT Doing
- No real ID or birthdate collection — decentralized app, can't verify, don't want the data
- No automated grooming pattern detection — too many false positives, too surveillance-like
- No automated reporting to authorities — user always decides
- No image retention for evidence — metadata and identifiers only, law enforcement retrieves content themselves
- No blocking all DMs by default — kills the social experience
- No server-side content analysis — privacy matters in a Nostr app
- No exposed reputation scores or formulas to regular users
- No keyword list as a primary defense — too easy to bypass
- No server-level reputation or "rotten server" blacklists — protection is per-user trust graph, not centralized judgment
