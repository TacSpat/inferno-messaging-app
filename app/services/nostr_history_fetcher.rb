# Fetches recent Nostr events from relays for a channel or conversation,
# importing any messages we don't already have.
class NostrHistoryFetcher
  # Fetch recent NIP-29 Kind 9 messages for a channel
  def self.fetch_channel(channel)
    return unless channel.nostr_group_id.present?

    since = channel.messages.maximum(:created_at)&.to_i || 1.day.ago.to_i
    filter = {
      kinds: [ 9 ],
      "#h" => [ channel.nostr_group_id ],
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

  def self.fetch_events(filter)
    RelayService.fetch_from_all(filter, timeout: 8)
  end

  def self.import_channel_events(channel, events)
    owner_pubkey = User.owner&.nostr_public_key
    imported = 0

    events.each do |event|
      next if NostrEventLog.already_processed?(event["id"])
      next if event["pubkey"] == owner_pubkey # Skip our own
      # Skip if a message with this event already exists (duplicate guard)
      next if channel.messages.exists?(nostr_event_id: event["id"])

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

      # Broadcast each message for real-time UI update
      html = ApplicationController.render(
        partial: "messages/message",
        locals: { message: message, server: channel.server }
      )
      ChannelChatChannel.broadcast_to(channel, { type: "new_message", html: html })

      imported += 1
    rescue ActiveRecord::RecordNotUnique
      next
    end

    Rails.logger.info("[NostrHistoryFetcher] Imported #{imported} channel messages for #{channel.name}") if imported > 0
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

      # Broadcast each message for real-time UI update
      html = ApplicationController.render(
        partial: "messages/dm_message",
        locals: { message: message }
      )
      ConversationChannel.broadcast_to(conversation, { type: "new_message", html: html })

      imported += 1
    rescue ActiveRecord::RecordNotUnique
      next
    end

    Rails.logger.info("[NostrHistoryFetcher] Imported #{imported} DMs for conversation #{conversation.id}") if imported > 0
  end
end
