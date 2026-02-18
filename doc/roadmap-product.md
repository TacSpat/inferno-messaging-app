# Product Roadmap

This document covers the product and growth roadmap for Inferno. For technical implementation details, see the other docs:

- [roadmap-cross-instance.md](roadmap-cross-instance.md) — federation implementation phases
- [voice-video-architecture.md](voice-video-architecture.md) — voice/video implementation
- [design-trust-compliance-monetization.md](design-trust-compliance-monetization.md) — trust tiers, payments, compliance

---

## Origin

Inferno was built in response to centralized chat platforms introducing invasive policies — ID verification requirements, opaque moderation, and unilateral terms changes — with no recourse for the communities affected. The goal is a chat app that feels as good as the best centralized platforms but can't be taken away from the people who use it.

---

## Principles

1. **Free and complete.** The software is free. The free experience is the full experience. No crippled tiers, no paywalls on core features. The moment a user hits a paywall before they love the product, they leave. TeamSpeak proved that charging for server software kills adoption.

2. **Invisible decentralization.** Users sign up with email and password. They never need to know what Nostr is, what a keypair is, or what federation means. The decentralization is a safety net they benefit from automatically, not a feature they have to understand.

3. **Inferno is Inferno.** Not a Discord clone. Not a Nostr client. Not "self-hosted X." A product with its own identity, its own UX, and its own reason to exist.

---

## Phase 1: Foundation (current — v0.1.x)

What exists today:

- Full messaging platform — text channels, DMs, voice/video, roles (38 permissions), custom emoji/stickers, GIF search, embeds, mentions, reactions
- Nostr identity — automatic keypair generation, NIP-05 verification, key export, profile publishing
- Cross-instance federation — remote auth, profile sync, remote server membership, cross-instance friends, shared channels (NIP-29)
- Admin tooling — instance config, federation mode, lockdown, suspensions, legal holds, audit logging, domain blocking, data exports, message retention
- Mobile-responsive web UI
- CI pipeline (RSpec, Minitest, Rubocop, Brakeman)
- AGPL-3.0 licensed

---

## Phase 2: Flagship Instance & Launch

**Goal:** Get real users on a real instance. Prove the product works for normal people.

- Launch a flagship Inferno instance (e.g. `inferno.chat`) — free, open registration
- This is the default "try it" experience — no self-hosting required to evaluate
- Build community on the flagship — dogfood the product, find bugs, collect feedback
- Create a landing page that explains Inferno in plain language with a "try it now" button that drops users straight into the flagship

**Getting eyes on it:**

- Post on Reddit (r/selfhosted, r/privacy, r/opensource, r/gaming), Hacker News, and Nostr when ready — one-time visibility spike
- Target communities already frustrated with centralized platforms. Every time a major platform makes a bad policy change, there's a wave of "where do we go?" — be the answer
- Migrate one real community (50-200 people) from Discord to the flagship and make sure their experience is great. They'll tell other communities. That's how Discord itself grew — one server at a time.
- Blog/changelog — "here's what we shipped" posts get picked up by aggregators and give people a reason to share

**Why this comes first:** Nothing else matters without users. A hosted instance costs one VPS ($20-40/month). Until there are people using Inferno daily, every other priority is premature.

---

## Phase 3: Native Apps & API Layer

**Goal:** Meet users where they are, and lay the foundation for a decoupled client.

- **JSON API** — add API endpoints alongside existing controllers. Same auth, same logic, JSON responses. The web UI stays server-rendered and untouched. The API enables native apps and future third-party clients.
- **Mobile (iOS + Android)** — Turbo Native wrapping the existing responsive web UI. Native push notifications, home screen presence, app store distribution — reusing 100% of existing views.
- **Desktop** — Tauri app wrapping the web UI. Lightweight, native-feeling, no Electron bloat.

**Client architecture:**

The web UI stays coupled to each instance — that's fine, it's fast. Decoupling happens at the native app layer. Native apps maintain two connections:

- **Home instance (always connected)** — identity, purchases, friends, cosmetics, notifications
- **Remote instances (per server)** — channels, messages, members

```
┌────────────────────────────────┐
│          Native App            │
│                                │
│   Home connection (persistent) │
│   ├── identity & profile       │
│   ├── purchases & cosmetics    │
│   ├── friends & notifications  │
│                                │
│   Remote connection (per server)│
│   ├── channels & messages      │
│   ├── members & roles          │
└──────┬──────────────┬──────────┘
       │              │
   Home Instance   Remote Instance
```

This means purchases and cosmetics always route through the home instance regardless of which server the user is browsing. The home instance is the source of truth for identity and owned items.

---

## Phase 4: Discovery & Federation Network

**Goal:** Multiple instances, real federation traffic, users can find communities from inside the app.

### Discovery via Nostr relays

No central registry. Instances publish their metadata and public server listings as Nostr events to relays — the same relays already used for identity and profile sync. Any Inferno instance can query relays to find other instances and servers. No gatekeeper controls visibility.

**Instance listing event** — each instance periodically publishes:
- Instance name, description, domain
- User count, federation mode
- Categories / tags

**Server listing event** — each instance publishes its discoverable servers:
- Server name, description, member count
- Tags / categories (gaming, tech, art, etc.)
- Instance domain (so the client knows where to send the user)

Instance operators choose which servers appear in discovery. Private servers stay private.

### In-app Explore page

An "Explore" button on the server rail (like a compass icon). Users search or browse by category. Results come from across the entire federation — servers on any instance. The user sees server name, description, member count, and a "Join" button. Cross-instance auth handles the rest. The user never needs to know or care which instance a server lives on.

### Bootstrapping

Early on, a default list of known instances ships with Inferno — a curated seed list. As the relay-based discovery populates, this becomes unnecessary.

### Self-hosting growth

- Improve onboarding for new instance admins — one-command setup, guided configuration
- Document self-hosting thoroughly (Docker Compose, cloud provider guides)
- Encourage community-run instances — gaming, open-source, regional, interest-based

**The moat starts here.** Once users have cross-instance friends, shared channels, and portable identities across multiple instances, the federation network itself becomes the value. Leaving Inferno means leaving that network — but unlike centralized platforms, no single entity controls it.

---

## Phase 5: Hosted Offering

**Goal:** Revenue from convenience, not from gating features.

- **Inferno Cloud** — managed hosting for people who want Inferno but don't want to run a server
- One-click instance provisioning, custom domains, automated backups, managed updates
- The software stays free and complete. Hosting is a convenience product, like WordPress.com next to WordPress.org.

Pricing model (approximate, adjust based on real costs):

| Tier | Price | Target |
|------|-------|--------|
| Self-host | Free | Developers, tinkerers, privacy maximalists |
| Starter | $5/month | Small friend groups, tryouts |
| Community | $15/month | Active communities, custom domain |
| Pro | $40/month | Large communities, priority support |

**Why this comes after users:** Nobody pays for hosting for an app they've never used from a project they've never heard of. The flagship instance (Phase 2) and organic self-hosting (Phase 4) create demand for managed hosting. Inferno Cloud captures the users who say "I love this but I don't want to run a server."

---

## Phase 6: Monetization & In-App Purchases

**Goal:** Sustainable revenue without paywalling core features.

Two payment rails: **Stripe** (cards, mainstream users) and **Bitcoin Lightning / Zaps** (NIP-57, low fees, Nostr-native). Users pick whichever they prefer. Instance operators can enable either or both.

### What's free (forever)

Messaging, voice, channels, roles, DMs, federation, identity, admin tools — everything that makes Inferno work. No "premium tier" that locks basic functionality.

### What users can buy

**Cosmetics** — the primary revenue source.
- Animated avatars, profile effects, custom profile colors, badges
- Premium sticker packs
- Cosmetics are stored as tags on the user's Nostr profile (Kind 0), so they travel across instances automatically. Remote instances render them. Instance operators can choose whether to display cosmetic purchases or not.

**Server boosts** — social support for communities.
- Users boost a server to show support. Boosted servers get a badge, boosters get a visible role.
- Boosts are social currency and financial support to the operator, not infrastructure upgrades. The operator controls their own instance limits — boosts don't change that.
- Boost revenue goes to the instance operator (minus a platform fee on Inferno Cloud).

**Verification badge** — proof of personhood.
- Small one-time payment (Stripe or Lightning) to get a verified badge.
- Unlocks higher rate limits and trust tier benefits (see design-trust-compliance-monetization.md).
- Not required for anything, but signals legitimacy.

**Tipping** — direct user-to-user support.
- Tip server owners, creators, or any user via Zaps (Lightning) or Stripe.
- Inferno takes a small platform fee. Instant settlement for Lightning.

### How purchases work across instances

- Purchases happen on the **home instance** (Stripe/Lightning transaction processed there).
- What you bought is published to your **Nostr profile** (Kind 0 metadata).
- Remote instances **render** your cosmetics by reading your profile — no payment processing needed on their end.
- Instance operators **opt in** to displaying cosmetic purchases. They can ignore them entirely.
- Native apps always route purchase flows through the home instance API, regardless of which server the user is browsing.

### Revenue split

| Source | Self-hosted instances | Inferno Cloud instances |
|--------|----------------------|------------------------|
| Cosmetics | 100% to operator | Revenue share (operator keeps majority) |
| Boosts | 100% to operator | Revenue share |
| Verification | 100% to operator | Revenue share |
| Tips | Passes through to recipient | Small platform fee |
| Hosting fee | N/A | Monthly subscription |

Self-hosted instances keep everything. Inferno Cloud instances share revenue as the cost of managed hosting. This incentivizes self-hosting (grows the network) while making the hosted offering sustainable.

See [design-trust-compliance-monetization.md](design-trust-compliance-monetization.md) for the full technical design (payment models, Stripe integration, Zap service, trust tiers).

---

## Phase 7: Product Depth

Features that deepen the platform beyond parity:

- **E2E encrypted DMs** — private conversations that even the instance operator can't read
- **2FA and OAuth** — Google/GitHub login, TOTP second factor
- **Bots and integrations API** — webhook endpoints, bot accounts, custom slash commands
- **Message search** — full-text search across channels and DMs
- **Threads** — threaded replies within channels for long discussions
- **Marketplace** — community-created themes, bot templates, sticker packs

---

## Phase 8: Enterprise

- **SSO/SAML** — corporate identity provider integration
- **Compliance certifications** — SOC 2, ISO 27001
- **SLAs and dedicated support** — for companies running Inferno internally
- **On-premise deployment consulting** — white-glove setup for organizations

---

## What Success Looks Like

Short-term: a flagship instance with an active community that people genuinely prefer over centralized alternatives.

Medium-term: a growing network of federated instances where users move freely between communities without creating new accounts.

Long-term: the default answer to "where should we host our community?" for anyone who cares about ownership — without requiring them to care about the technology that makes it possible.
