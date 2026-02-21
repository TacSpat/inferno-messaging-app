# Plan: Secure Invite Links + Cross-Instance Invite Cards

## Overview
1. Make invite codes more secure (longer)
2. Add instance branding to invite pages + OpenGraph meta tags for rich link previews
3. Public JSON API for invite metadata (federation)
4. In-chat Inferno invite link embeds (like existing YouTube/Discord embeds)

---

## Step 1: Longer Invite Codes

**File:** `app/models/invite.rb`
- Change `SecureRandom.alphanumeric(8)` → `SecureRandom.alphanumeric(16)`
- Existing codes remain valid (no migration needed)

---

## Step 2: OpenGraph Meta Tags on Invite Page

**File:** `app/views/invites/show.html.erb`
- Add `content_for :head` block with OG tags:
  - `og:title` — "Join {server_name} on Inferno"
  - `og:description` — server description or "{X} members"
  - `og:image` — banner URL (fallback: icon URL)
  - `og:url` — canonical invite URL
  - `og:site_name` — "Inferno · {instance_domain}"
  - `twitter:card` — "summary_large_image"

**File:** `app/views/layouts/application.html.erb`
- Add `<%= yield :head %>` inside `<head>` to render the OG tags

---

## Step 3: Instance Branding on Invite Page

**File:** `app/views/invites/show.html.erb`
- Add instance domain badge/pill below the banner (e.g., "Inferno · beast-mint.tail84ddc9.ts.net")
- Visual cue that this is an Inferno server from a specific instance

---

## Step 4: Public Invite Metadata JSON API

**File:** `app/controllers/invites_controller.rb`
- Add `respond_to` block in `show` action:
  - HTML: existing invite page
  - JSON: return server metadata (name, description, icon_url, banner_url, member_count, online_count, instance_domain)
- Icon/banner URLs use `rails_blob_url` for absolute URLs

---

## Step 5: In-Chat Inferno Invite Embeds

**File:** `app/models/message.rb`
- Add `INFERNO_INVITE_REGEX` to match invite URLs from any Inferno instance (pattern: `https://.../invite/CODE`)
- Add invite link detection in `unfurl_links`:
  - **Local invites**: Look up server directly, render rich card inline (banner, icon, name, members)
  - **Remote invites**: Fetch metadata via JSON API from the remote instance (async via job, like Tenor)
  - Strip the raw URL link, replace with an embedded card
- Card design: Banner at top, icon overlapping, server name, member counts, instance domain, "Join Server" link

**File:** `app/jobs/invite_unfurl_job.rb` (new)
- Background job that fetches remote invite metadata from the JSON API
- Updates the cached rendered content with the rich card
- Broadcasts the update via ActionCable (same pattern as TenorUnfurlJob)

---

## Files Changed
1. `app/models/invite.rb` — longer codes
2. `app/views/invites/show.html.erb` — OG tags + instance branding
3. `app/views/layouts/application.html.erb` — `yield :head`
4. `app/controllers/invites_controller.rb` — JSON response
5. `app/models/message.rb` — invite regex + unfurl logic
6. `app/jobs/invite_unfurl_job.rb` — new async job for remote invite cards

## Files NOT Changed
- Routes (existing `GET /invite/:code` handles JSON via respond_to)
- No new migrations needed
