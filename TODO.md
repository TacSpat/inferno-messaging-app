# Flutter Rewrite — Remaining Features

Features present in the Rails app but missing or stubbed in Flutter.

## High Priority

- [ ] **Member Moderation** — Wire kick/ban/timeout handlers to publish Nostr events (UI stubs exist with empty handlers)
- [x] **Server Invites** — Create invites with expiration/max uses, share naddr codes, revoke invites (can join by code but can't create/manage)
- [x] **Mention Autocomplete** — @user autocomplete popup while typing in message input
- [x] **Message Pinning** — Pin/unpin messages, system message on pin, pinned messages list (header icon exists, handler empty)
- [ ] **DM Voice Calls** — Initiate call, incoming ring notification, accept/decline, 30s timeout, call duration tracking

## Medium Priority

- [ ] **Server Onboarding** — Rules display on join, self-assignable roles, default channel selection
- [x] **Audit Log** — View Nostr event history per server (Kind 30000+ events)
- [x] **Custom Emoji Management** — Upload, delete, manage server emojis (display works, CRUD missing)
- [x] **Custom Sticker Management** — Upload, delete, manage stickers with Blossom CDN
- [x] **Channel Category CRUD** — Create, edit, delete, reorder categories (display works, management missing)
- [ ] **Push-to-Talk** — Wire input mode toggle + keybind to LiveKit audio (setting UI exists)
- [ ] **Screen Sharing** — Wire LiveKit screen share (button exists, needs testing/completion)
- [ ] **Notifications Backend** — Connect desktop notification toggles to system notifications (UI exists, not wired)
- [x] **Encrypted Channel Creation** — Create new encrypted channels with role-based access (can read existing, can't create)

## Low Priority

- [ ] **Server Folders** — Group servers into folders in the server rail
- [ ] **Message Thread View** — Dedicated thread/reply chain view (reply works, thread panel missing)
- [ ] **Keybinds Settings** — Custom keyboard shortcut configuration screen
- [ ] **NIP-05 Verification** — Display verified badge in profiles (service exists, not wired to UI)
- [ ] **NIP-51 Mute Lists** — Publish block list to Nostr relays (blocking works locally, not published)
- [ ] **Content Safety / NSFW** — NSFW image scanning, blur, hide, report flow
- [ ] **Member Pruning** — Remove inactive members after configurable days
- [x] **AFK Channel** — Auto-move users to AFK channel after idle timeout
- [ ] **Batch Moderation** — Bulk kick/ban/timeout operations
- [ ] **Member Nicknames** — Per-server display name overrides
- [ ] **Password/Account Management** — Password change, account deletion
- [ ] **NIP-65 Relay Lists** — Publish relay preferences to Nostr (Kind 10002)
- [ ] **Blossom Server Config** — Configurable Blossom upload server URLs in settings
- [x] **Message Search Filters** — from:user, in:channel, date range filters (basic search works)
- [x] **Video Player** — Inline video playback for video URLs/embeds
