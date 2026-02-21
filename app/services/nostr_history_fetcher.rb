# Fetches recent Nostr events from relays for a channel or conversation,
# importing any messages we don't already have.
class NostrHistoryFetcher
  # Fetch recent NIP-29 Kind 9 messages for a channel
  def self.fetch_channel(channel)
    return unless channel.nostr_group_id.present?

    since = channel.messages.maximum(:created_at)&.to_i || 1.day.ago.to_i
    filter = {
      kinds: [9],
      "#h" => [channel.nostr_group_id],
      since: since
    }

    events = fetch_events(filter)
    import_channel_events(channel, events)
  rescue => e
    Rails.logger.error("[NostrHistoryFetcher] Channel fetch error: #{e.message}")
  end

  # Fetch recent NIP-44 Kind 14 DMs for a conversation
  def self.fetch_conversation(conversation)
    owner = User.owner
    return unless owner&.nostr_private_key.present?
    return unless conversation.counterparty_pubkey.present?

    since = conversation.messages.maximum(:created_at)&.to_i || 1.day.ago.to_i

    # Fetch events tagged to our pubkey from the counterparty
    filter = {
      kinds: [14, 1059, 4],
      "#p" => [owner.nostr_public_key],
      authors: [conversation.counterparty_pubkey],
      since: since
    }

    events = fetch_events(filter)
    import_dm_events(conversation, owner, events)
  rescue => e
    Rails.logger.error("[NostrHistoryFetcher] Conversation fetch error: #{e.message}")
  end

  private

  def self.fetch_events(filter)
    urls = RelayConnection.active.pluck(:url)
    all_events = {}
    mutex = Mutex.new

    threads = urls.map do |url|
      Thread.new do
        events = RelayService.fetch_from_relay(url, filter, timeout: 8)
        mutex.synchronize do
          events.each { |e| all_events[e["id"]] ||= e }
        end
      rescue => e
        Rails.logger.warn("[NostrHistoryFetcher] Relay #{url} failed: #{e.message}")
      end
    end

    # Wait up to 10s for all relays
    threads.each { |t| t.join(10) }
    threads.each { |t| t.kill if t.alive? }

    all_events.values
  end

  def self.import_channel_events(channel, events)
    owner_pubkey = User.owner&.nostr_public_key
    imported = 0

    events.each do |event|
      next if NostrEventLog.already_processed?(event["id"])
      next if event["pubkey"] == owner_pubkey # Skip our own

      sender_pubkey = event["pubkey"]
      contact = Contact.find_or_initialize_by(pubkey: sender_pubkey)
      if contact.new_record? || contact.profile_stale?
        NostrProfileResolver.resolve(sender_pubkey) rescue nil
      end

      message = channel.messages.create!(
        content: event["content"],
        public_id: SecureRandom.alphanumeric(12),
        nostr_event_id: event["id"],
        nostr_author_pubkey: sender_pubkey,
        created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
      )

      NostrEventLog.create!(
        event_id: event["id"],
        kind: event["kind"],
        pubkey: sender_pubkey,
        message: message,
        channel: channel,
        direction: "inbound",
        event_created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
      )

      imported += 1
    rescue ActiveRecord::RecordNotUnique
      next
    end

    if imported > 0
      Rails.logger.info("[NostrHistoryFetcher] Imported #{imported} channel messages for #{channel.name}")
      # Broadcast to refresh the channel
      ChannelChatChannel.broadcast_to(channel, { type: "history_sync", count: imported })
    end
  end

  def self.import_dm_events(conversation, owner, events)
    imported = 0

    events.each do |event|
      next if NostrEventLog.already_processed?(event["id"])
      next if event["pubkey"] == owner.nostr_public_key # Skip our own

      sender_pubkey = event["pubkey"]

      begin
        conversation_key = Nip44Service.conversation_key(owner.nostr_private_key, sender_pubkey)
        plaintext = Nip44Service.decrypt(event["content"], conversation_key)
      rescue Nip44Service::DecryptionError
        next
      end

      # Skip friend request/response messages
      parsed = JSON.parse(plaintext) rescue nil
      next if parsed.is_a?(Hash) && %w[friend_request friend_response].include?(parsed["type"])

      message = conversation.messages.create!(
        content: plaintext,
        public_id: SecureRandom.alphanumeric(12),
        nostr_event_id: event["id"],
        created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
      )

      NostrEventLog.create!(
        event_id: event["id"],
        kind: event["kind"],
        pubkey: sender_pubkey,
        direction: "inbound",
        event_created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
      )

      imported += 1
    rescue ActiveRecord::RecordNotUnique
      next
    end

    if imported > 0
      Rails.logger.info("[NostrHistoryFetcher] Imported #{imported} DMs for conversation #{conversation.id}")
      ConversationChannel.broadcast_to(conversation, { type: "history_sync", count: imported })
    end
  end
end
