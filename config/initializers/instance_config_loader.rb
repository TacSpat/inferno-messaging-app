# Nostr instance keypair — read exclusively from ENV (never from YAML).
# Used by NostrReportPublishJob and strfry pubkey sync.
#
# Generate with: rails nostr:generate_instance_keypair
Rails.application.config.nostr = {
  instance_private_key: ENV["NOSTR_INSTANCE_PRIVATE_KEY"].presence,
  instance_public_key: ENV["NOSTR_INSTANCE_PUBLIC_KEY"].presence
}
