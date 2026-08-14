# Remediation Plan — `flutter-rewrite`

Derived from the 2026-08-13 audit of commit `95d6a0c`, after roughly three and a half months of dormancy. Seven research agents worked from a knowledge graph of the Flutter app, the legacy Rails reference, and the docs, then verified every claim against real source. **95 open issues**, indexed by tracking issue #114.

This document is the execution order. The issues hold the evidence; this holds the sequencing and the reasoning behind it.

---

## Where the damage is

| Area | Issues | Critical | High |
|---|---:|---:|---:|
| Moderation / compliance | 16 | 3 | 8 |
| Sync / caching / rate limiting | 15 | 2 | 6 |
| DM parity | 14 | 4 | 4 |
| UI parity | 14 | 1 | 7 |
| Build size | 12 | 1 | 3 |
| Multi-device | 11 | 3 | 6 |
| Performance / theming | 9 | 2 | 4 |
| Docs | 3 | 0 | 1 |
| **Total** | **95** | **16** | **40** |

Severity split: 16 critical, 40 high, 30 medium, 8 low.

## The structural insight

**The 16 criticals are not 16 problems. They are 6 workstreams.** Most cluster onto a single root cause with a single fix, which is what makes the early phases cheap:

| Workstream | Criticals | One root cause |
|---|---|---|
| Asset path | #84, #95 (+#96) | One doubly-nested directory |
| Relay layer | #22, #23 | Dedup set + never CLOSEing subscriptions |
| Publish wiring | #58, #59, #60 | Publish methods exist, are never called |
| Group DMs | #45, #46, #47 | Feature scaffolded, never wired |
| Theme / rebuild | #35, #38 | Rebuilds triggered at the wrong tree level |
| Safety substrate | #99 | Hash list has no source |

Only two criticals stand alone: #44 (DM calls are dead code) and #70 (invented hover language).

## The cross-cutting pattern

A striking share of findings are **dead code that reads as a shipped feature**: `CallService`, `CallScreen`, `DmRequestBanner`, `NotificationService`, `Blocks`, `ConversationParticipants`, `MembersScreen`, `publishRelayList`, `schedulePublish`, plus nine unreferenced widgets and two unreferenced methods the analyzer already flags. The UI repeatedly offers an affordance that silently does nothing — "New Group Chat", Delete/Edit/Pin in DMs, kick/ban/timeout.

The analyzer corroborates this independently: run from the repo root, warnings are dominated by `unused_import` (31), `unused_field` (22), `unnecessary_non_null_assertion` (22), `unused_local_variable` (20), `unused_element` (18).

**Suggested convention going forward: unwired UI is hidden, not inert.** A disabled control that explains itself is fine. A live-looking control that does nothing is a bug report waiting to happen, and it is why several of these issues took an agent hours to characterise.

---

## P0 — Blocks everything else

### #115 — Two complete Dart source trees are tracked in git

Root `lib/` is **live** (last touched by `046c5c7`, the newest code commit). `flutter/lib/` is **stale** (one commit behind). 183 files each; they differ in only six files, which is exactly what makes it dangerous — you can read, edit, and even run `flutter analyze` against the wrong one without noticing.

Nothing else in this plan is safe until this is resolved, because a fix can land in the tree that never ships.

**Do:** confirm root `lib/` is authoritative, diff the six divergent files in both directions and port anything missing, then delete the `flutter/` Dart tree in one clearly-titled commit. Deduplicate `doc/` vs `flutter/doc/` at the same time.

The six divergent files are the auth flow and the theme table — `screens/auth/{key_import,login,setup_wizard,signup}_screen.dart`, `screens/conversations/conversations_list_screen.dart`, `theme/all_themes.dart` — i.e. precisely where the most recent work happened.

**Also re-verify before acting:** issues #35, #36, #46, #50, #56, #73, #83 cite one of those six files.

---

## P1 — Silently broken, cheap to fix

The highest value per hour in the whole plan. Every item here is small and repairs something that is currently inert.

### #84 / #95 / #96 — The doubly-nested asset path

Models live at `assets/models/assets/models/` while `pubspec.yaml:124` declares `assets/models/`, and Flutter directory asset declarations are **not recursive**. Confirmed against the shipped `AssetManifest.bin`: no model entries at all. Both loaders swallow the exception, so **NSFW detection and DeepFilterNet noise suppression are silently off in every shipped build.** The same nesting bypassed `.gitignore` (globs match one path segment) and committed 29.66 MB to git.

One path fix closes two criticals, restores audio processing, and reclaims repo weight. #96 is adjacent and should be done in the same pass: prefilter-only mode drops stage 5, so even a loaded model can never flag anything.

Fixing this **adds** ~29.66 MB to the bundle. A correct Linux build is ~160 MB installed, not today's 118.96 MB — design against that number, and pair this with the size work in P4.

### #22 / #23 — The relay layer

Two bugs explain most of the reported "sync issues when navigating around" and all of the rate-limiting complaints.

- **#22:** a process-wide event-ID dedup set returns *before* dispatching to subscription callbacks, so any event delivered once can never be returned by a later `fetch()`. Eight services depend on `fetch()`. This is also why the `fetchFresh()` throwaway-socket path exists at all — it is a workaround for this bug, at the cost of ~40 WebSocket handshakes per server sync (#24).
- **#23:** long-lived REQ subscriptions are never CLOSEd, so they accumulate per relay until the relay rate-limits. **The rate limiting is a leak, not a tuning problem.**

Rails already solved #23: `RelaySubscriptionManager#refresh_subscriptions` CLOSEs every tracked subscription before resubscribing. Porting that one method fixes the leak and takes **#25** (subscriptions never refreshed after bootstrap) with it.

### #85 — CI never runs `scripts/strip_release.sh`

The script already exists and is simply never called. Measured: **−31.12 MB installed, −21.7% download.** A one-line CI change and the single cheapest win in the audit.

### #26 — The `insertOnConflictUpdate` landmine is live

`_fetchOwnProfile` uses `insertOnConflictUpdate` against `contacts.pubkey`, a non-primary-key unique constraint, inside a bare `catch(_)`. The user's own profile silently never updates after first insert. Four more unused DAO helpers carry the same pattern and should be removed before someone calls them.

### #116 — Two compile errors in dead code

`lib/widgets/gif_picker.dart` has two hard type errors. The app builds only because the file is imported nowhere. Delete it (it is superseded by `unified_picker.dart`) so the analyzer is trustworthy again.

---

## P2 — Multi-device foundation

Today, two devices on the same identity share almost nothing. This phase is mostly **wiring, not design** — the publish half is already written.

### #58 / #59 / #60 — Cross-device sync is write-never

`ConfigSyncService.schedulePublish`, `publishServerList`, and `RelaySyncService.publishRelayList` are all dead code with zero callers; only the read half runs. Device B queries for a config that was never written and starts empty. Separately, `ensureDefaultRelays()` deletes every user-added relay on each launch, which defeats relay sync even once publishing works — and is a single-device bug too.

**Do:** call the existing debounced publish methods on join/leave and on settings save; fix `ensureDefaultRelays` to merge rather than replace. Order matters — fix #60 first or the other two cannot persist.

### #48 — DM reactions leak private metadata

Published as plaintext public Kind 7 events. Labeled high, but this is a **privacy leak, not a missing feature**, and it is cheap to fix. Pulled forward into P2 deliberately.

### #66 / #65 — Voice breaks across devices

LiveKit participant identity is derived deterministically from the pubkey, so **a second device evicts the first** via `DUPLICATE_IDENTITY`, and the reconnect logic means the two devices plausibly fight in a loop. Kind 10070 voice state has no `d` tag, so it is plain-replaceable per `(pubkey, kind)`: one voice state per user globally, a leave on device A wipes a join on device B, and there is no expiry — a crash leaves the user permanently in-voice to everyone.

### #64 / #68 — Lost-update clobbering

Server-config, profile, and contact-list publishes all write a **full snapshot from a possibly-stale local cache** with no compare-and-swap. Two devices silently undo each other's edits. Same bug class as the "Accidental Backdate" already reverted once.

### #62 / #63 — Read state and catch-up window

Unread badges are local-only and hardcoded to `userId 0`, and newly-synced channels seed as fully read, so badges are wrong in both directions and users learn to ignore them. Live subscriptions use a fixed 24-hour catch-up window even though a `backfillDays` setting already exists and defaults to 30.

---

## P3 — Performance and the theme stutter

### #35 / #36 / #37 — Theme switching

Theme switching rebuilds the **entire GoRouter page stack three times**. The spinner overlay does not mask the jank — it adds 200ms of dead time and doubles the rebuild count, because toggling the flag at the root rebuilds everything on its own.

**Do:** inject `Theme` below the Router, never at the root; memoize `ThemeData` in a Provider or const map instead of building it inline in `build()`; if the spinner is kept at all, isolate it in its own `ConsumerWidget`.

This supersedes the previous project guidance to swap `ThemeData` behind a spinner overlay. The full-`ThemeData` half of that guidance still holds; the spinner half was measured harmful.

### #38 — `setState` inside `build()`

`MessageInput` schedules `setState` from inside `build()`, a self-sustaining per-frame rebuild loop. Independent of theming and worth fixing regardless.

### #39 / #40 — Continuous animation and re-parsing

`ui_effects` animations run at 60fps forever, rebuild via `setState`, and repaint without a `RepaintBoundary`. `MessageContent` re-parses markdown and re-runs URL regexes on every rebuild.

### #41 / #42 / #43 — Rebuild scope

Keep-alive on media messages keeps every scrolled-past embed mounted; `Image.network` is used at 20+ sites with no `cacheWidth`/`cacheHeight`; only one riverpod `.select` appears across 178 `ref.watch` calls.

---

## P4 — Feature parity

### Group DMs — #45 / #46 / #47 as one feature

The "New Group Chat" button does nothing, `ConversationParticipants` is never read or written, and the send path hard-returns when `counterpartyPubkey` is null. Three criticals, one feature. Do not attempt them separately.

### #44 — Voice/video calls in DMs

`CallService` and `CallScreen` are dead code. Larger than it looks; sequence it after group DMs so the participant model exists first.

### #49 / #50 / #51 / #55 — The inert affordances

Delete/Edit/Pin in the DM context menu silently do nothing; search and pinned messages are hard-gated on an active server channel; `DmRequestBanner` is dead code so there is no first-contact protection; `NotificationService` is a complete stub that is never called.

### Build size — #86 / #87 / #88 / #89 / #90 / #91

Three byte-identical 16 MB copies of `libonnxruntime.so` are committed to git. Android is a fat multi-ABI build that would bundle a **Linux x86-64 `.so`** as its native lib. `NotoColorEmoji.ttf` costs 10.18 MB on every platform. 664 MB of unused NSFW model families and 2.8 GB of untracked, un-gitignored directories sit at the repo root, two files exceeding GitHub's 100 MB limit.

Target: strip + drop the desktop emoji font + an int8-quantized bundled model lands a **fully functional** Linux build at ~90 MB installed, versus ~160 MB if the asset bug is fixed with no other change.

---

## P5 — UI parity and polish

### #70 — The invented hover language

Flutter introduced an accent-gradient + 2px left accent border + glow hover treatment used on channel items, member items, message rows, the server header and dropdowns. Rails uses flat neutral fills throughout. **This is the single biggest reason the two apps read differently**, and it breaks non-red themes. Do this one first in the phase.

### #73 — 201 hardcoded colors

201 hardcoded `Color(0x...)` values outside `theme/`, including an entire navy palette that exists in no theme. Both a parity break and the reason theming cannot fully take effect — surfaces that cannot respond to a theme change look like a theming bug but are not.

### #71 / #72 / #75 / #76 / #79 / #81

Message rows are 6x less dense than Rails (12px vs 2px padding). Mention badges missing from the server rail, home button, and channel sidebar. Hover toolbar missing Hide Message and Toggle Spoiler while adding an ungated Delete. Channel screen missing four Rails states (read-only banner, post-only banner, new-message jump bar, named empty state). User panel has no status picker at all. Member context menu missing the Roles submenu and friendship-state actions, with Mention a no-op and Change Nickname discarding input.

---

## Decisions that are not an engineer's to make

### #111 — Licensing

The documentation describes **two mutually incompatible products under two incompatible licenses**: an AGPL-3.0 Rails federated monolith and an Elastic License 2.0 serverless client. There are two `LICENSE` files. AGPL requires source disclosure to network users; ELv2 is not open source and forbids offering the software as a hosted service.

Shipping a binary built from a tree containing both, without stating which governs, is real legal exposure. **This should be settled before any release work**, and it is far cheaper to resolve now than after.

### Moderation compliance posture

16 issues, 3 critical. Today the pipeline is well-designed on paper and largely inert in practice:

- AI flagging cannot initialize (#95) and could not flag anything even if it did (#96)
- CSAM hash matching is a placeholder with no authoritative source, empty on every install (#99)
- Blocking does not filter channel messages and the `Blocks` table is dead code (#103)
- Inbound bans are logged but never enforced; timeouts never enforced at all (#104)
- No age verification; the NSFW gate is a click-through with no age assertion (#107)
- No audit logging, no data export/DSAR, no retention policy, no appeals path (#108)
- The authority report is clipboard-only, omits content hashes, and misstates which relays carried the message (#109)
- Shared-hash promotion lets a handful of contacts permanently and irreversibly mark arbitrary images as CSAM (#100) — an abuse vector in its own right

**If this ships to real users, that list is the exposure to price.** The engineering is tractable; the question of what posture is acceptable at launch is a business and legal decision.

---

## Verified working — do not "fix" these

- **DM multi-device delivery (#69, closed).** Self-authored Kind 14 events are subscribed to and attributed properly, so the classic dual-encryption multi-device bug is **not** present. Checked deliberately because it would have been severe and hard to notice. Silently dropping either the `authors` filter or the `isOwnEvent` branch would reintroduce it — worth a regression test.
- **Profile (kind 0) and friends (kind 3) sync** across devices correctly.
- **The codebase compiles and the architecture is sound.** Most criticals are unwired code paths, not bad design. That is what makes this plan tractable.

---

## Baseline for measuring progress

- `flutter analyze` **from the repo root**: 358 issues — 4 errors, 124 warnings, 230 info. (Run from `flutter/` it reports 183 and 0 errors, because that is the stale tree. Always run from root.)
- The 4 errors are 2 real errors duplicated across both trees, in `lib/widgets/gif_picker.dart:35,42`.
- Linux release bundle: 124,741,264 bytes = **118.96 MB installed / 42.73 MB packaged**.
- No Windows/macOS/Android build output exists locally and CI reports no sizes, so those are unmeasured (#92).

## Already fixed since the audit

Three `IgnorePointer` sites in `lib/widgets/message_content.dart` — the inline video controls bar, the fullscreen close button, and the fullscreen controls bar. Faded-out controls remained hit-testable, swallowing clicks on the video surface and throwing `Cannot hit test a render box that has never been laid out`. Confirmed resolved by the reporter.
