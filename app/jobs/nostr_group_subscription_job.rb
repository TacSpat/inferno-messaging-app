class NostrGroupSubscriptionJob < ApplicationJob
  queue_as :default

  NIP29_GROUP_CHAT_MESSAGE = 9

  # Subscribe to all shared channels and process inbound events
  def perform
    shared_channels = Channel.shared_channels.where.not(nostr_relay_url: nil, nostr_group_id: nil)
    return if shared_channels.empty?

    # Group channels by relay URL to minimize connections
    channels_by_relay = shared_channels.group_by(&:nostr_relay_url)

    channels_by_relay.each do |relay_url, channels|
      process_relay(relay_url, channels)
    end
  end

  private

  def process_relay(relay_url, channels)
    group_ids = channels.map(&:nostr_group_id)
    channel_map = channels.index_by(&:nostr_group_id)

    # Fetch recent Kind 9 events for these groups
    # Use a since timestamp to avoid re-fetching old messages
    oldest_log = NostrEventLog.inbound
      .where(channel: channels)
      .order(event_created_at: :desc)
      .first

    since = oldest_log ? oldest_log.event_created_at.to_i : 1.hour.ago.to_i

    filter = {
      kinds: [ NIP29_GROUP_CHAT_MESSAGE ],
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

    # Skip events from local users (we already have these)
    local_user = User.local.find_by(nostr_public_key: pubkey)
    return if local_user

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

    # Find or create remote user
    remote_user = RemoteUser.find_by(nostr_public_key: pubkey)
    unless remote_user
      remote_user = RemoteUser.find_or_create_from_auth(
        public_key: pubkey,
        home_instance: "unknown",
        username: "nostr_#{pubkey[0..7]}"
      )
    end
    remote_user.reload
    shadow_user = remote_user.shadow_user

    return unless shadow_user

    # Create the local message
    message = channel.messages.create!(
      user: shadow_user,
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

    # Broadcast via ActionCable so local users see it in real time
    broadcast_message(message, channel)
  rescue ActiveRecord::RecordNotUnique
    # Race condition: another process already inserted this event
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

    # Broadcast unread indicator
    channel.server.members.where.not(id: message.user_id).find_each do |member|
      ActionCable.server.broadcast("user_notifications_#{member.id}", {
        type: "channel_message",
        server_id: channel.server.public_id,
        channel_id: channel.public_id,
        user_id: message.user.public_id
      })
    end
  end
end
