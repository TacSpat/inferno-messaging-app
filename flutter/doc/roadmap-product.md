# Product Roadmap

This document covers the product and growth roadmap for Inferno. For technical implementation details, see the other docs:

- [roadmap.md](roadmap.md) - technical implementation status and plans
- [voice-video-architecture.md](voice-video-architecture.md) - voice/video implementation
- [design-trust-compliance-monetization.md](design-trust-compliance-monetization.md) - trust, payments, compliance

---

## Origin

Inferno was built in response to centralized chat platforms introducing invasive policies - ID verification requirements, opaque moderation, and unilateral terms changes - with no recourse for the communities affected. The goal is a chat app that feels as good as the best centralized platforms but can't be taken away from the people who use it.

---

## Principles

1. **Free and complete.** The software is free. The free experience is the full experience. No crippled tiers, no paywalls on core features.

2. **Invisible decentralization.** Users sign up with email and password. They never need to know what Nostr is, what a keypair is, or how relays work. The decentralization is a safety net they benefit from automatically, not a feature they have to understand.

3. **Inferno is Inferno.** Not a Discord clone. Not a Nostr client. Not "self-hosted X." A product with its own identity, its own UX, and its own reason to exist.

4. **Your data, your device.** Inferno runs on your machine. Server state, messages, and identity sync through Nostr relays - no central server holds your community hostage.

---

## Phase 1: The App (current - v0.1.x)

What exists today:

- Native cross-platform app - Windows, Linux, macOS, Android, iOS - built with Flutter
- Relay-first architecture - the app connects directly to Nostr relays. No intermediary server. All server state, messages, DMs, and profiles sync through relays (Kinds 9, 14, 30315, 31750-31757)
- Full messaging platform - text channels, DMs, voice/video, roles (30+ permissions), custom emoji/stickers, GIF search, embeds, mentions, reactions
- Nostr identity - automatic keypair generation, NIP-05 verification, key export, profile publishing
- Encrypted channels - NIP-44 (XChaCha20-Poly1305) for private channels
- Remote member support - users from other Nostr clients can be tracked and assigned roles
- Admin tooling - usage limits, lockdown, suspensions, audit logging, data exports, message retention
- Voice and video - LiveKit SFU integration, screen sharing, moderation controls
- Local storage - Drift (SQLite) database on-device for offline access and fast queries
- Elastic License 2.0

---

## Phase 2: Polish & Launch

**Goal:** Get real users. Prove the product works for normal people.

- Build a landing page that explains Inferno in plain language
- Package platform builds - `flutter build` for Windows (.msix), macOS (.dmg), Linux (.deb/.AppImage), Android (.apk/.aab), iOS (.ipa)
- Publish to app stores - Google Play, Apple App Store, Microsoft Store, Flathub/Snap
- Target communities frustrated with centralized platforms - every time a major platform makes a bad policy change, there's a wave of "where do we go?"
- Post on Reddit (r/selfhosted, r/privacy, r/opensource, r/gaming), Hacker News, and Nostr when ready
- Migrate one real community (50-200 people) and make sure their experience is great

**Why this comes first:** Nothing else matters without users. Until there are people using Inferno daily, every other priority is premature.

---

## Phase 3: Discovery

**Goal:** Users can find communities from inside the app.

### Discovery via Nostr Relays

No central registry. Servers publish their metadata as Nostr events to relays. Any Inferno instance can query relays to find servers. No gatekeeper controls visibility.

### In-App Explore Page

An "Explore" button on the server rail (compass icon). Users search or browse by category. Results come from across the relay network - servers on any instance. Users see server name, description, member count, and a "Join" button. They never need to know or care where a server is hosted.

---

## Phase 4: Monetization

**Goal:** Sustainable revenue without paywalling core features.

Two payment rails: **Stripe** (cards, mainstream users) and **Bitcoin Lightning / Zaps** (NIP-57, low fees, Nostr-native). Users pick whichever they prefer.

### What's free (forever)

Messaging, voice, channels, roles, DMs, identity, admin tools - everything that makes Inferno work. No "premium tier" that locks basic functionality.

### What users can buy

**Cosmetics** - the primary revenue source.
- Animated avatars, profile effects, custom profile colors, badges
- Premium sticker packs
- Cosmetics stored as tags on the user's Nostr profile (Kind 0), so they travel with the user automatically

**Server boosts** - social support for communities.
- Users boost a server to show support. Boosted servers get a badge, boosters get a visible role.
- Boosts are social currency, not infrastructure upgrades.

**Verification badge** - proof of personhood.
- Small one-time payment (Stripe or Lightning) for a verified badge.
- Not required for anything, but signals legitimacy.

**Tipping** - direct user-to-user support.
- Tip creators or any user via Zaps (Lightning) or Stripe.
- Instant settlement for Lightning.

---

## Phase 5: Product Depth

Features that deepen the platform beyond parity:

- **E2E encrypted DMs** - private conversations that not even the app can read (NIP-44 client-side encryption)
- **NIP-46 remote signing** - delegate signing to a remote signer (Nostr Connect), so users can manage keys with dedicated key management apps like nsecBunker instead of trusting raw key material to the client
- **Bots and integrations API** - webhook endpoints, bot accounts, custom slash commands
- **Message search** - full-text search across channels and DMs
- **Threads** - threaded replies within channels for long discussions
- **Marketplace** - community-created themes, bot templates, sticker packs

---

## What Success Looks Like

Short-term: active communities that people genuinely prefer over centralized alternatives.

Medium-term: a growing ecosystem of Nostr-connected communities where users move freely between servers with portable identity.

Long-term: the default answer to "where should we host our community?" for anyone who cares about ownership - without requiring them to care about the technology that makes it possible.
