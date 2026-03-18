# Fetches recent Nostr events from relays for a channel or conversation,
# importing any messages we don't already have.
class NostrHistoryFetcher
  # Fetch recent NIP-29 Kind 9 messages for a channel
  def self.fetch_channel(channel)
    return unless channel.nostr_group_id.present?
    config = LocalConfig.current
    return unless config.backfill_enabled

    since = config.backfill_days.days.ago.to_i

    # Fetch messages (Kind 9), deletes (Kind 9005), and pins (Kind 9006)
    filter = {
      kinds: [ 9, 9005, 9006 ],
      "#h" => [ channel.nostr_group_id ],
      since: since
    }

    events = fetch_events(filter)

    # Split by kind and process in order: messages first, then deletes/edits, then pins
    messages = events.select { |e| e["kind"] == 9 }
    deletes = events.select { |e| e["kind"] == 9005 }
    pins = events.select { |e| e["kind"] == 9006 }

    import_channel_events(channel, messages)
    apply_channel_deletes(channel, deletes)
    apply_channel_pins(channel, pins)
  rescue => e
    Rails.logger.error("[NostrHistoryFetcher] Channel fetch error: #{e.message}")
  end

  # Fetch recent NIP-44 Kind 14 DMs for a conversation
  def self.fetch_conversation(conversation)
    owner = User.owner
    return unless owner&.nostr_private_key.present?
    return unless conversation.counterparty_pubkey.present?
    config = LocalConfig.current
    return unless config.backfill_enabled

    since = config.backfill_days.days.ago.to_i

    # Fetch events tagged to our pubkey from the counterparty
    filter = {
      kinds: [ 14, 1059, 4 ],
      "#p" => [ owner.nostr_public_key ],
      authors: [ conversation.counterparty_pubkey ],
      since: since
    }

    events = fetch_events(filter)
    import_dm_events(conversation, owner, events)
  rescue => e
    Rails.logger.error("[NostrHistoryFetcher] Conversation fetch error: #{e.message}")
  end

  private

  # Delete messages that were removed via Kind 9005 events
  def self.apply_channel_deletes(channel, delete_events)
    return if delete_events.empty?

    delete_events.each do |event|
      next if NostrEventLog.already_processed?(event["id"])

      target_tag = (event["tags"] || []).find { |t| t[0] == "e" }
      next unless target_tag

      target_event_id = target_tag[1]
      message = channel.all_messages.find_by(nostr_event_id: target_event_id)
      message&.destroy

      NostrEventLog.create!(
        event_id: event["id"],
        kind: event["kind"],
        pubkey: event["pubkey"],
        channel: channel,
        direction: "inbound",
        event_created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
      )
    rescue ActiveRecord::RecordNotUnique
      next
    end
  end

  # Apply pin state from Kind 9006 events
  def self.apply_channel_pins(channel, pin_events)
    return if pin_events.empty?

    # Process in chronological order so the latest pin state wins
    pin_events.sort_by { |e| e["created_at"].to_i }.each do |event|
      next if NostrEventLog.already_processed?(event["id"])

      tags = event["tags"] || []
      target_tag = tags.find { |t| t[0] == "e" }
      pinned_tag = tags.find { |t| t[0] == "pinned" }
      next unless target_tag

      target_event_id = target_tag[1]
      pinned = pinned_tag&.dig(1) == "true"

      message = channel.all_messages.find_by(nostr_event_id: target_event_id)
      message&.update_columns(pinned: pinned)

      NostrEventLog.create!(
        event_id: event["id"],
        kind: event["kind"],
        pubkey: event["pubkey"],
        channel: channel,
        direction: "inbound",
        event_created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
      )
    rescue ActiveRecord::RecordNotUnique
      next
    end
  end

  def self.fetch_events(filter)
    RelayService.fetch_from_all(filter, timeout: 8)
  end

  def self.import_channel_events(channel, events)
    return if events.empty?

    owner_pubkey = User.owner&.nostr_public_key

    # Batch dedup: check which events we've already processed or imported
    event_ids = events.map { |e| e["id"] }.compact
    existing_event_ids = NostrEventLog.where(event_id: event_ids).pluck(:event_id).to_set
    existing_nostr_ids = channel.messages.where(nostr_event_id: event_ids).pluck(:nostr_event_id).to_set

    # Filter to new events only
    new_events = events.reject { |e|
      e["pubkey"] == owner_pubkey ||
      existing_event_ids.include?(e["id"]) ||
      existing_nostr_ids.include?(e["id"])
    }
    return if new_events.empty?

    # Batch contact lookup: resolve all unique pubkeys at once
    pubkeys = new_events.map { |e| e["pubkey"] }.uniq
    contacts_by_pubkey = Contact.where(pubkey: pubkeys).index_by(&:pubkey)
    stale_pubkeys = pubkeys.select { |pk|
      contact = contacts_by_pubkey[pk]
      contact.nil? || contact.profile_stale?
    }
    stale_pubkeys.each { |pk| NostrProfileResolver.resolve(pk) rescue nil }

    imported = 0
    newest_message = nil

    new_events.each do |event|
      sender_pubkey = event["pubkey"]

      is_spoiler = (event["tags"] || []).any? { |t| t[0] == "spoiler" }

      content = event["content"]
      next if content.blank? # Skip empty events (file-only messages without Blossom URLs)

      message = channel.messages.create!(
        content: content,
        public_id: SecureRandom.alphanumeric(12),
        nostr_event_id: event["id"],
        nostr_author_pubkey: sender_pubkey,
        spoiler: is_spoiler,
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

      unless message.hidden?
        newest_message = message if newest_message.nil? || message.created_at > newest_message.created_at
        imported += 1
      end
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
      next
    end

    if imported > 0
      Rails.logger.info("[NostrHistoryFetcher] Imported #{imported} channel messages for #{channel.name}")
      ChannelChatChannel.broadcast_to(channel, {
        type: "backfill_complete",
        count: imported,
        newest_id: newest_message&.public_id
      })
    end
  end

  def self.import_dm_events(conversation, owner, events)
    return if events.empty?

    # Batch dedup
    event_ids = events.map { |e| e["id"] }.compact
    existing_event_ids = NostrEventLog.where(event_id: event_ids).pluck(:event_id).to_set

    new_events = events.reject { |e|
      e["pubkey"] == owner.nostr_public_key ||
      existing_event_ids.include?(e["id"])
    }
    return if new_events.empty?

    imported = 0
    newest_message = nil

    new_events.each do |event|
      sender_pubkey = event["pubkey"]

      begin
        conversation_key = Nip44Service.conversation_key(owner.nostr_private_key, sender_pubkey)
        plaintext = Nip44Service.decrypt(event["content"], conversation_key)
      rescue Nip44Service::DecryptionError
        next
      end

      # Extract content from structured payloads (same logic as RelaySubscriptionManager)
      content = plaintext
      files = nil
      emoji_urls = nil
      begin
        parsed = JSON.parse(plaintext)
        if parsed.is_a?(Hash)
          if parsed["type"] == "message"
            content = parsed["content"] || ""
            files = parsed["files"]
            if files.is_a?(Array) && files.any?
              content += "\n" unless content.empty?
              content += files.join("\n")
            end
            emoji_urls = parsed["emojis"] if parsed["emojis"].is_a?(Hash)
          elsif parsed.key?("type")
            # Skip non-message payloads (friend_request, friend_response, message_delete, message_edit, etc.)
            next
          end
        end
      rescue JSON::ParserError
        # Plain text — use as-is
      end

      # Cache remote file URLs locally
      if files.is_a?(Array) && files.any?
        cached = RemoteAssetCache.cache_all(files)
        cached.each { |remote, local| content = content.gsub(remote, local) }
      end

      # Replace custom emoji shortcodes with locally-cached images
      if emoji_urls.present?
        emoji_urls.each do |name, url|
          cached_url = RemoteAssetCache.cache(url) || url
          img = %(<img src="#{ERB::Util.html_escape(cached_url)}" alt=":#{ERB::Util.html_escape(name)}:" class="inline-block align-text-bottom" style="height:1.375em;width:auto" loading="lazy">)
          content = content.gsub(/:#{Regexp.escape(name)}:/i, img)
        end
      end

      next if content.blank?

      # Skip if message already exists (additional dedup after batch check)
      next if conversation.messages.exists?(nostr_event_id: event["id"])

      message = conversation.messages.create!(
        content: content,
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

      unless message.hidden?
        newest_message = message if newest_message.nil? || message.created_at > newest_message.created_at
        imported += 1
      end
    rescue ActiveRecord::RecordNotUnique
      next
    end

    if imported > 0
      Rails.logger.info("[NostrHistoryFetcher] Imported #{imported} DMs for conversation #{conversation.id}")
      ConversationChannel.broadcast_to(conversation, {
        type: "backfill_complete",
        count: imported,
        newest_id: newest_message&.public_id
      })
    end
  end
end
