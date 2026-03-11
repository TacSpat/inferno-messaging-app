# Idempotent seed data — safe to run multiple times.
# Executed by `rails db:seed` or `rails db:prepare` on first boot.

# ── Default relays ───────────────────────────────────────────
%w[
  wss://relay.damus.io
  wss://nos.lol
  wss://relay.snort.social
].each do |url|
  RelayConnection.find_or_create_for_relay(url)
end

# ── Default Blossom servers ──────────────────────────────────
config = LocalConfig.current
if config.blossom_server_urls.blank?
  config.update!(blossom_server_urls: %w[
    https://blossom.primal.net
    https://cdn.satellite.earth
  ])
end

# ── Default safety protection level ─────────────────────────
config.apply_protection_level!("standard") if config.safety_protection_level.blank?
