class NostrGroupSubscriptionJob < ApplicationJob
  queue_as :default

  NIP29_GROUP_CHAT_MESSAGE = 9

  # Subscribe to all channels and process inbound events from relays
  def perform
    channels = Channel.where.not(nostr_group_id: [nil, ""])
    return if channels.empty?

    channels_by_relay = channels.group_by(&:nostr_relay_url).reject { |url, _| url.blank? }

    channels_by_relay.each do |relay_url, channels|
      process_relay(relay_url, channels)
    end
  end

  private

  def process_relay(relay_url, channels)
    group_ids = channels.map(&:nostr_group_id)
    channel_map = channels.index_by(&:nostr_group_id)

    oldest_log = NostrEventLog.inbound
      .where(channel: channels)
      .order(event_created_at: :desc)
      .first

    since = oldest_log ? oldest_log.event_created_at.to_i : 1.hour.ago.to_i

    filter = {
      kinds: [NIP29_GROUP_CHAT_MESSAGE],
      "#h" => group_ids,
      since: since
    }

    events = RelayService.fetch_from_relay(relay_url, filter, timeout: 30)

    events.each do |event_data|
      process_event(event_data, channel_map)
    end

    Rails.logger.info("Processed #{events.length} events from #{relay_url} for #{channels.length} channels")
  rescue StandardError => e
    Rails.logger.error("NostrGroupSubscriptionJob error for #{relay_url}: #{e.message}")
  end

  def process_event(event_data, channel_map)
    event_id = event_data["id"]

    # Skip if already processed
    return if NostrEventLog.already_processed?(event_id)

    # Find the target channel from the group tag
    group_tag = (event_data["tags"] || []).find { |t| t[0] == "h" }
    return unless group_tag

    group_id = group_tag[1]
    channel = channel_map[group_id]
    return unless channel

    pubkey = event_data["pubkey"]
    content = event_data["content"]

    # Skip events from our own user
    owner = User.owner
    return if owner&.nostr_public_key == pubkey

    # Verify the event signature
    begin
      NostrEventService.verify_schnorr_signature(
        message_hex: event_id,
        pubkey_hex: pubkey,
        signature_hex: event_data["sig"]
      )
    rescue NostrEventService::InvalidSignature => e
      Rails.logger.warn("Invalid signature on inbound event #{event_id}: #{e.message}")
      return
    end

    # Create the local message (attributed to owner for now — will be improved with Contact model)
    message = channel.messages.create!(
      content: content,
      public_id: SecureRandom.alphanumeric(12)
    )

    # Log the inbound event
    NostrEventLog.create!(
      event_id: event_id,
      kind: event_data["kind"],
      pubkey: pubkey,
      message: message,
      channel: channel,
      direction: "inbound",
      event_created_at: event_data["created_at"] ? Time.at(event_data["created_at"]) : Time.current
    )

    broadcast_message(message, channel)
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue StandardError => e
    Rails.logger.error("Error processing inbound event #{event_data['id']}: #{e.message}")
  end

  def broadcast_message(message, channel)
    html = ApplicationController.render(
      partial: "messages/message",
      locals: { message: message, server: channel.server }
    )

    ChannelChatChannel.broadcast_to(channel, {
      type: "new_message",
      html: html
    })
  end
end
