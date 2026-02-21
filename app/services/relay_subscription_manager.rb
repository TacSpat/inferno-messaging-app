require "faye/websocket"
require "eventmachine"

# Persistent WebSocket pool to all configured relays.
# Maintains subscriptions for NIP-29 groups (channels), Kind 4/14 (DMs),
# Kind 0 (profiles), and Kind 30315 (presence/status).
#
# Usage:
#   RelaySubscriptionManager.instance.start
#   RelaySubscriptionManager.instance.stop
#
class RelaySubscriptionManager
  include Singleton

  NIP29_GROUP_CHAT_MESSAGE = 9
  NIP29_DELETE_EVENT = 9005
  KIND_METADATA = 0
  KIND_ENCRYPTED_DM = 4
  KIND_GIFT_WRAP = 1059
  KIND_DM = 14
  KIND_USER_STATUS = 30315

  RECONNECT_DELAY = 5 # seconds

  attr_reader :connections, :running

  def initialize
    @connections = {} # relay_url => { ws:, subscriptions:, reconnect_timer: }
    @running = false
    @mutex = Mutex.new
  end

  def start
    return if @running

    @running = true
    Rails.logger.info("[RelaySubscriptionManager] Starting relay subscription manager")

    Thread.new do
      EventMachine.run do
        connect_to_all_relays
      end
    end
  end

  def stop
    @running = false
    @mutex.synchronize do
      @connections.each do |url, conn|
        EventMachine.cancel_timer(conn[:reconnect_timer]) if conn[:reconnect_timer]
        conn[:ws]&.close rescue nil
      end
      @connections.clear
    end
    EventMachine.stop if EventMachine.reactor_running?
    Rails.logger.info("[RelaySubscriptionManager] Stopped")
  end

  def relay_urls
    RelayConnection.active.pluck(:url)
  end

  # Reconnect to relays (e.g. when relay list changes)
  def refresh_connections
    return unless @running && EventMachine.reactor_running?

    EventMachine.next_tick do
      current_urls = relay_urls
      @mutex.synchronize do
        (@connections.keys - current_urls).each do |url|
          Rails.logger.info("[RelaySubscriptionManager] Disconnecting from removed relay: #{url}")
          @connections[url][:ws]&.close rescue nil
          @connections.delete(url)
        end
      end
      (current_urls - @connections.keys).each do |url|
        connect_to_relay(url)
      end
    end
  end

  private

  def connect_to_all_relays
    relay_urls.each do |url|
      connect_to_relay(url)
    end
  end

  def connect_to_relay(url)
    Rails.logger.info("[RelaySubscriptionManager] Connecting to #{url}")

    ws = Faye::WebSocket::Client.new(url)

    @mutex.synchronize do
      @connections[url] = { ws: ws, subscriptions: {}, reconnect_timer: nil }
    end

    ws.on :open do |_event|
      Rails.logger.info("[RelaySubscriptionManager] Connected to #{url}")
      subscribe_all(url, ws)
    end

    ws.on :message do |event|
      handle_message(url, event.data)
    end

    ws.on :close do |_event|
      Rails.logger.warn("[RelaySubscriptionManager] Disconnected from #{url}")
      schedule_reconnect(url) if @running
    end

    ws.on :error do |event|
      Rails.logger.error("[RelaySubscriptionManager] Error on #{url}: #{event.message rescue 'unknown'}")
    end
  end

  def subscribe_all(url, ws)
    owner = User.owner
    return unless owner

    # Subscription 1: NIP-29 group messages for all channels
    group_ids = Channel.where.not(nostr_group_id: nil).pluck(:nostr_group_id)
    if group_ids.any?
      sub_id = "groups-#{SecureRandom.hex(4)}"
      filter = {
        kinds: [NIP29_GROUP_CHAT_MESSAGE, NIP29_DELETE_EVENT],
        "#h" => group_ids,
        since: 1.hour.ago.to_i
      }
      ws.send(JSON.generate(["REQ", sub_id, filter]))
      @mutex.synchronize { @connections[url][:subscriptions][sub_id] = :groups }
    end

    # Subscription 2: DMs for our pubkey
    if owner.nostr_public_key.present?
      sub_id = "dms-#{SecureRandom.hex(4)}"
      filter = {
        kinds: [KIND_GIFT_WRAP, KIND_DM, KIND_ENCRYPTED_DM],
        "#p" => [owner.nostr_public_key],
        since: 1.hour.ago.to_i
      }
      ws.send(JSON.generate(["REQ", sub_id, filter]))
      @mutex.synchronize { @connections[url][:subscriptions][sub_id] = :dms }
    end

    # Subscription 3: Profile + presence updates from contacts
    contact_pubkeys = Contact.friends.pluck(:pubkey)
    if contact_pubkeys.any?
      sub_id = "contacts-#{SecureRandom.hex(4)}"
      filter = {
        kinds: [KIND_METADATA, KIND_USER_STATUS],
        authors: contact_pubkeys
      }
      ws.send(JSON.generate(["REQ", sub_id, filter]))
      @mutex.synchronize { @connections[url][:subscriptions][sub_id] = :contacts }
    end
  end

  def handle_message(relay_url, raw_data)
    data = JSON.parse(raw_data) rescue nil
    return unless data.is_a?(Array)

    case data[0]
    when "EVENT"
      event = data[2]
      process_inbound_event(event) if event.is_a?(Hash)
    when "EOSE"
      Rails.logger.debug("[RelaySubscriptionManager] EOSE from #{relay_url} for #{data[1]}")
    when "OK"
      Rails.logger.debug("[RelaySubscriptionManager] OK from #{relay_url}: #{data[2]}")
    when "NOTICE"
      Rails.logger.warn("[RelaySubscriptionManager] NOTICE from #{relay_url}: #{data[1]}")
    end
  end

  def process_inbound_event(event)
    event_id = event["id"]
    return if event_id.blank?

    # Deduplicate
    return if NostrEventLog.already_processed?(event_id)

    kind = event["kind"]
    pubkey = event["pubkey"]

    # Skip our own events
    owner = User.owner
    return if owner&.nostr_public_key == pubkey

    case kind
    when NIP29_GROUP_CHAT_MESSAGE
      process_group_message(event)
    when NIP29_DELETE_EVENT
      process_group_delete(event)
    when KIND_DM, KIND_GIFT_WRAP, KIND_ENCRYPTED_DM
      process_dm_event(event)
    when KIND_METADATA
      process_profile_update(event)
    when KIND_USER_STATUS
      process_presence_event(event)
    end
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing event #{event['id']}: #{e.message}")
  end

  def process_group_message(event)
    group_tag = (event["tags"] || []).find { |t| t[0] == "h" }
    return unless group_tag

    group_id = group_tag[1]
    channel = Channel.find_by(nostr_group_id: group_id)
    return unless channel

    # Check if this is an edit (has an "e" tag with "edit" marker)
    edit_tag = (event["tags"] || []).find { |t| t[0] == "e" && t[3] == "edit" }
    if edit_tag
      process_group_edit(channel, event, edit_tag[1])
      return
    end

    # Resolve the sender — ensure we have a Contact record with profile info
    sender_pubkey = event["pubkey"]
    contact = Contact.find_or_initialize_by(pubkey: sender_pubkey)
    if contact.new_record? || contact.profile_stale?
      NostrProfileResolver.resolve(sender_pubkey)
      contact.reload if contact.persisted?
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

    html = ApplicationController.render(
      partial: "messages/message",
      locals: { message: message, server: channel.server }
    )
    ChannelChatChannel.broadcast_to(channel, { type: "new_message", html: html })
  rescue ActiveRecord::RecordNotUnique
    # Already processed by another connection
  end

  def process_group_edit(channel, event, original_event_id)
    message = Message.find_by(nostr_event_id: original_event_id, channel: channel)
    return unless message

    message.update!(content: event["content"], edited_at: Time.current)

    html = ApplicationController.render(
      partial: "messages/message",
      locals: { message: message, server: channel.server }
    )
    ChannelChatChannel.broadcast_to(channel, {
      type: "update_message",
      message_id: message.public_id,
      html: html
    })

    Rails.logger.info("[RelaySubscriptionManager] Edited channel message #{original_event_id}")
  end

  def process_group_delete(event)
    group_tag = (event["tags"] || []).find { |t| t[0] == "h" }
    return unless group_tag

    channel = Channel.find_by(nostr_group_id: group_tag[1])
    return unless channel

    # Find the event being deleted
    event_tag = (event["tags"] || []).find { |t| t[0] == "e" }
    return unless event_tag

    target_event_id = event_tag[1]
    message = Message.find_by(nostr_event_id: target_event_id, channel: channel)
    return unless message

    message_public_id = message.public_id
    message.destroy

    ChannelChatChannel.broadcast_to(channel, {
      type: "delete_message",
      message_id: message_public_id
    })

    Rails.logger.info("[RelaySubscriptionManager] Deleted channel message #{target_event_id}")
  end

  def process_dm_event(event)
    owner = User.owner
    return unless owner&.nostr_private_key.present?

    sender_pubkey = event["pubkey"]

    # Decrypt NIP-44 content
    conversation_key = Nip44Service.conversation_key(owner.nostr_private_key, sender_pubkey)
    plaintext = Nip44Service.decrypt(event["content"], conversation_key)

    # Try to parse as JSON (friend request/response) or treat as plain DM text
    parsed = JSON.parse(plaintext) rescue nil

    if parsed.is_a?(Hash) && parsed["type"] == "friend_request"
      process_friend_request(sender_pubkey, event)
    elsif parsed.is_a?(Hash) && parsed["type"] == "friend_response"
      process_friend_response(sender_pubkey, parsed["status"], event)
    elsif parsed.is_a?(Hash) && parsed["type"] == "message_edit"
      process_dm_edit(sender_pubkey, parsed, event)
    elsif parsed.is_a?(Hash) && parsed["type"] == "message_delete"
      process_dm_delete(sender_pubkey, parsed, event)
    elsif parsed.is_a?(Hash) && parsed["type"] == "message"
      # Structured message with possible file attachments
      content = parsed["content"] || ""
      files = parsed["files"]
      if files.is_a?(Array) && files.any?
        content += "\n" unless content.empty?
        content += files.join("\n")
      end
      process_dm_message(sender_pubkey, content, event)
    else
      # Regular DM message (plain text)
      process_dm_message(sender_pubkey, plaintext, event)
    end

    NostrEventLog.create!(
      event_id: event["id"],
      kind: event["kind"],
      pubkey: sender_pubkey,
      direction: "inbound",
      event_created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
    )
  rescue Nip44Service::DecryptionError => e
    Rails.logger.warn("[RelaySubscriptionManager] Failed to decrypt DM from #{event["pubkey"]&.first(12)}: #{e.message}")
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def process_friend_request(sender_pubkey, event)
    contact = Contact.find_or_initialize_by(pubkey: sender_pubkey)

    # Don't overwrite an existing accepted friendship
    return if contact.accepted?

    # Resolve their profile from the event or relays
    contact.friendship_status = :pending_incoming
    contact.save!

    # Fetch their profile in background
    NostrProfileResolver.resolve(sender_pubkey)

    # Notify the owner via ActionCable
    owner = User.owner
    if owner
      ActionCable.server.broadcast("user_notifications_#{owner.id}", {
        type: "friend_request",
        from_pubkey: sender_pubkey,
        from_name: contact.effective_display_name
      })
    end

    Rails.logger.info("[RelaySubscriptionManager] Incoming friend request from #{sender_pubkey.first(12)}...")
  end

  def process_friend_response(sender_pubkey, status, event)
    contact = Contact.find_by(pubkey: sender_pubkey)
    return unless contact

    case status
    when "accepted"
      contact.update!(friendship_status: :accepted)
      # Publish updated Kind 3 contact list
      owner = User.owner
      NostrPublishJob.perform_later(owner.id, :contacts) if owner
      Rails.logger.info("[RelaySubscriptionManager] Friend request accepted by #{sender_pubkey.first(12)}...")
    when "declined"
      contact.update!(friendship_status: :declined)
      Rails.logger.info("[RelaySubscriptionManager] Friend request declined by #{sender_pubkey.first(12)}...")
    end
  end

  def process_dm_message(sender_pubkey, plaintext, event)
    owner = User.owner
    return unless owner

    # Find or create conversation by counterparty pubkey
    conversation = Conversation.find_or_create_by_pubkey(owner, sender_pubkey)

    # Create the message
    message = conversation.messages.create!(
      content: plaintext,
      public_id: SecureRandom.alphanumeric(12),
      nostr_event_id: event["id"],
      created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
    )

    # Broadcast via ActionCable for real-time display
    html = ApplicationController.render(
      partial: "messages/dm_message",
      locals: { message: message }
    )
    ConversationChannel.broadcast_to(conversation, { type: "new_message", html: html })

    # Notify the owner
    contact = Contact.find_by(pubkey: sender_pubkey)
    sender_name = contact&.effective_display_name || sender_pubkey.first(12) + "..."
    ActionCable.server.broadcast("user_notifications_#{owner.id}", {
      type: "dm_message",
      conversation_id: conversation.public_id,
      sender_name: sender_name,
      sender_id: nil
    })

    Rails.logger.info("[RelaySubscriptionManager] Received DM from #{sender_pubkey.first(12)}...")
  end

  def process_dm_edit(sender_pubkey, parsed, event)
    original_event_id = parsed["event_id"]
    new_content = parsed["content"]
    return if original_event_id.blank? || new_content.blank?

    message = Message.find_by(nostr_event_id: original_event_id)
    return unless message

    message.update!(content: new_content, edited_at: Time.current)

    conversation = message.conversation
    return unless conversation

    html = ApplicationController.render(
      partial: "messages/dm_message",
      locals: { message: message }
    )
    ConversationChannel.broadcast_to(conversation, {
      type: "update_message",
      message_id: message.public_id,
      html: html
    })

    Rails.logger.info("[RelaySubscriptionManager] Edited DM #{original_event_id} from #{sender_pubkey.first(12)}...")
  end

  def process_dm_delete(sender_pubkey, parsed, event)
    original_event_id = parsed["event_id"]
    return if original_event_id.blank?

    message = Message.find_by(nostr_event_id: original_event_id)
    return unless message

    conversation = message.conversation
    message_public_id = message.public_id
    message.destroy

    if conversation
      ConversationChannel.broadcast_to(conversation, {
        type: "delete_message",
        message_id: message_public_id
      })
    end

    Rails.logger.info("[RelaySubscriptionManager] Deleted DM #{original_event_id} from #{sender_pubkey.first(12)}...")
  end

  def process_profile_update(event)
    pubkey = event["pubkey"]
    contact = Contact.find_by(pubkey: pubkey)
    return unless contact

    metadata = JSON.parse(event["content"]) rescue nil
    return unless metadata

    contact.update_from_metadata(metadata)
    Rails.logger.debug("[RelaySubscriptionManager] Profile update for #{pubkey[0..15]}...")
  end

  # Process NIP-38 Kind 30315 user status events
  def process_presence_event(event)
    pubkey = event["pubkey"]
    contact = Contact.find_by(pubkey: pubkey)
    return unless contact

    status_tag = (event["tags"] || []).find { |t| t[0] == "status" }
    state = status_tag&.dig(1) || event["content"]
    return if state.blank?

    if state == "offline"
      contact.update_columns(last_seen_at: nil)
    else
      contact.update_columns(last_seen_at: Time.current)
    end

    # Broadcast presence change to owner's UI
    owner = User.owner
    if owner
      ActionCable.server.broadcast("user_notifications_#{owner.id}", {
        type: "presence",
        user_id: "contact-#{contact.id}",
        pubkey: pubkey,
        name: contact.effective_display_name,
        state: state == "offline" ? "offline" : "online"
      })
    end

    Rails.logger.debug("[RelaySubscriptionManager] Presence: #{contact.effective_display_name} is #{state}")
  end

  def schedule_reconnect(url)
    return unless @running

    EventMachine.add_timer(RECONNECT_DELAY) do
      if @running
        Rails.logger.info("[RelaySubscriptionManager] Reconnecting to #{url}")
        connect_to_relay(url)
      end
    end
  end
end
