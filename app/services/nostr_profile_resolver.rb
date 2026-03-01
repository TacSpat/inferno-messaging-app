# Fetches Kind 0 (profile metadata) events from relays for a given pubkey.
# Caches results in Contact records.
class NostrProfileResolver
  KIND_METADATA = 0

  # Resolve a profile by pubkey, returning the Contact record
  def self.resolve(pubkey, relay_urls: nil)
    contact = Contact.find_or_initialize_by(pubkey: pubkey)

    # Skip if recently fetched
    return contact if contact.persisted? && !contact.profile_stale?

    urls = relay_urls || RelayConnection.active.pluck(:url)
    return contact if urls.empty?

    filter = {
      kinds: [ KIND_METADATA ],
      authors: [ pubkey ],
      limit: 1
    }

    # Collect events from all relays and use the most recent one
    all_events = []
    urls.each do |url|
      events = RelayService.fetch_from_relay(url, filter, timeout: 10)
      all_events.concat(events)
    rescue => e
      Rails.logger.debug("NostrProfileResolver relay #{url} error: #{e.message}")
    end

    metadata = nil
    if all_events.any?
      newest = all_events.max_by { |e| e["created_at"].to_i }
      begin
        metadata = JSON.parse(newest["content"])
      rescue JSON::ParserError
        # skip
      end
    end

    if metadata
      contact.update_from_metadata(metadata)
      contact.relay_url ||= urls.first
      contact.save! if contact.changed?
    elsif contact.new_record?
      contact.save!
    end

    contact
  rescue => e
    Rails.logger.error("NostrProfileResolver error for #{pubkey}: #{e.message}")
    contact.save! if contact.new_record?
    contact
  end

  # Batch resolve multiple pubkeys
  def self.resolve_batch(pubkeys)
    pubkeys.each do |pubkey|
      resolve(pubkey)
    end
  end
end
