# Periodically fetches kind 1984 (NIP-56 report) events from relays
# and extracts shared image hashes from ["x"] tags.
class FetchSharedHashesJob < ApplicationJob
  queue_as :default

  def perform
    config = LocalConfig.current
    return unless config.safety_shared_hashes_enabled
    return unless config.safety_image_hash_enabled

    since = 24.hours.ago.to_i
    filter = { kinds: [ 1984 ], since: since }

    events = RelayService.fetch_from_all(filter, timeout: 15)
    processed = 0

    events.each do |event|
      next unless event.is_a?(Hash)
      process_report_event(event, config)
      processed += 1
    end

    Rails.logger.info("[FetchSharedHashesJob] Processed #{processed} report events")
  end

  private

  def process_report_event(event, config)
    tags = event["tags"] || []
    pubkey = event["pubkey"]
    event_id = event["id"]
    return if pubkey.blank? || event_id.blank?

    x_tags = tags.select { |t| t[0] == "x" && t[1].present? && t[2].present? }
    return if x_tags.empty?

    x_tags.each do |tag|
      hash_value = tag[1]
      hash_type = tag[2]

      ch = ContentHash.find_or_initialize_by(hash_value: hash_value, hash_type: hash_type, source: "shared")
      reporter_pubkeys = ch.reporter_pubkeys || []
      nostr_event_ids = ch.nostr_event_ids || []

      next if reporter_pubkeys.include?(pubkey)

      reporter_pubkeys << pubkey
      nostr_event_ids << event_id

      ch.reporter_pubkeys = reporter_pubkeys
      ch.nostr_event_ids = nostr_event_ids
      ch.reporter_count = reporter_pubkeys.size
      ch.confidence = compute_confidence(reporter_pubkeys, config)
      ch.source = "shared"
      ch.save!
    end
  end

  def compute_confidence(reporter_pubkeys, config)
    reporter_pubkeys.sum do |pubkey|
      weight_for_pubkey(pubkey, config)
    end
  end

  def weight_for_pubkey(pubkey, config)
    return 1.0 unless config.safety_shared_hash_trust_friends

    contact = Contact.find_by(pubkey: pubkey)
    if contact&.accepted?
      1.0   # Friend
    elsif contact
      0.3   # Known contact
    else
      0.1   # Stranger
    end
  end
end
