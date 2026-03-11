# Searches Nostr relays for user profiles using NIP-50 (search) and NIP-05 resolution.
class NostrSearchService
  KIND_METADATA = 0

  Result = Struct.new(:pubkey, :display_name, :name, :avatar_url, :nip05, :bio, :contact_status, keyword_init: true)

  # Main entry point: search by name, npub, hex pubkey, or NIP-05 identifier.
  # Returns an array of Result structs, deduplicated by pubkey.
  def self.search(query)
    query = query.to_s.strip
    return [] if query.blank?

    results = {}

    # 1) If it looks like an npub, resolve directly
    if query.start_with?("npub1")
      pubkey = decode_npub(query)
      if pubkey
        merge_profile(results, resolve_pubkey(pubkey))
        return finalize(results)
      end
    end

    # 2) If it looks like a hex pubkey, resolve directly
    if query.match?(/\A[0-9a-f]{64}\z/i)
      merge_profile(results, resolve_pubkey(query.downcase))
      return finalize(results)
    end

    # 3) If it looks like a NIP-05 identifier (user@domain), try resolution
    if query.include?("@")
      nip05_results = resolve_nip05(query)
      nip05_results.each { |r| merge_profile(results, r) }
    end

    # 4) NIP-50 relay search (keyword-based)
    relay_results = nip50_search(query)
    relay_results.each { |r| merge_profile(results, r) }

    finalize(results)
  end

  # Dedicated NIP-50 search relays (most relays don't support NIP-50)
  NIP50_RELAYS = %w[
    wss://search.nos.today
    wss://relay.nostr.band
  ].freeze

  # NIP-50 search: query all relays in parallel, return as soon as any has results
  def self.nip50_search(query)
    filter = { kinds: [ KIND_METADATA ], search: query, limit: 20 }

    urls = (NIP50_RELAYS + RelayConnection.active.pluck(:url)).uniq
    all_events = {}
    mutex = Mutex.new
    got_results = Queue.new

    threads = urls.map do |url|
      Thread.new do
        timeout = NIP50_RELAYS.include?(url) ? 10 : 5
        events = RelayService.fetch_from_relay(url, filter, timeout: timeout)
        if events.any?
          mutex.synchronize { events.each { |e| all_events[e["id"]] = e } }
          got_results.push(true)
        end
      rescue => e
        Rails.logger.warn("NIP-50 relay #{url} failed: #{e.message}")
      end
    end

    # Wait for first relay to return results, or all to finish (max 10s)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if remaining <= 0
      break if got_results.pop(timeout: [ remaining, 0.5 ].min)
      break if threads.none?(&:alive?)
    end

    # Give a brief moment for other fast relays to also return
    sleep(0.3) if all_events.any?
    threads.each { |t| t.kill if t.alive? }

    all_events.values.filter_map { |event| parse_kind0_event(event) }
  rescue => e
    Rails.logger.error("NostrSearchService NIP-50 error: #{e.message}")
    []
  end

  # Resolve a NIP-05 identifier (user@domain) to a profile
  def self.resolve_nip05(identifier)
    parts = identifier.split("@", 2)
    return [] unless parts.length == 2

    name, domain = parts
    return [] if name.blank? || domain.blank?

    url = "https://#{domain}/.well-known/nostr.json?name=#{CGI.escape(name)}"
    response = fetch_url(url)
    return [] unless response

    data = JSON.parse(response)
    names = data["names"] || {}
    pubkey = names[name] || names[name.downcase]
    return [] unless pubkey.is_a?(String) && pubkey.match?(/\A[0-9a-f]{64}\z/i)

    # Fetch the full profile for this pubkey
    [ resolve_pubkey(pubkey) ].compact
  rescue => e
    Rails.logger.error("NostrSearchService NIP-05 error for #{identifier}: #{e.message}")
    []
  end

  # Resolve a single pubkey by fetching Kind 0 from relays
  def self.resolve_pubkey(pubkey)
    filter = { kinds: [ KIND_METADATA ], authors: [ pubkey ], limit: 1 }
    events = RelayService.fetch_from_all(filter, timeout: 10)

    if events.any?
      event = events.max_by { |e| e["created_at"].to_i }
      parse_kind0_event(event)
    else
      # Return a minimal result even without metadata
      Result.new(pubkey: pubkey, display_name: nil, name: nil, avatar_url: nil, nip05: nil, bio: nil)
    end
  rescue => e
    Rails.logger.error("NostrSearchService resolve_pubkey error for #{pubkey}: #{e.message}")
    Result.new(pubkey: pubkey, display_name: nil, name: nil, avatar_url: nil, nip05: nil, bio: nil)
  end

  private

  def self.parse_kind0_event(event)
    metadata = JSON.parse(event["content"]) rescue nil
    return nil unless metadata.is_a?(Hash)

    Result.new(
      pubkey: event["pubkey"],
      display_name: metadata["display_name"].presence || metadata["name"],
      name: metadata["name"],
      avatar_url: metadata["picture"],
      nip05: metadata["nip05"],
      bio: metadata["about"]
    )
  end

  def self.decode_npub(npub)
    decoded = Nostr::Bech32.decode(npub)[:data]
    decoded if decoded.is_a?(String) && decoded.length == 64
  rescue
    nil
  end

  def self.merge_profile(results, result)
    return unless result&.pubkey.present?
    # Keep the result with more metadata
    existing = results[result.pubkey]
    if existing.nil? || (result.display_name.present? && existing.display_name.blank?)
      results[result.pubkey] = result
    end
  end

  def self.finalize(results)
    own_pubkey = User.first&.nostr_public_key
    results.values.map do |r|
      # Skip our own pubkey
      next if r.pubkey == own_pubkey

      contact = Contact.find_by(pubkey: r.pubkey)
      r.contact_status = if contact&.accepted?
        "friend"
      elsif contact&.pending_outgoing?
        "pending_outgoing"
      elsif contact&.pending_incoming?
        "pending_incoming"
      else
        nil
      end
      r
    end.compact
  end

  def self.fetch_url(url, timeout: 5)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = timeout
    http.read_timeout = timeout

    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/json"
    response = http.request(request)

    response.code == "200" ? response.body : nil
  rescue => e
    Rails.logger.error("NostrSearchService fetch_url error for #{url}: #{e.message}")
    nil
  end
end
