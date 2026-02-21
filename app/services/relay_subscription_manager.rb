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

  # Re-subscribe on all connections (e.g. when contacts/friends list changes)
  def refresh_subscriptions
    return unless @running && EventMachine.reactor_running?

    EventMachine.next_tick do
      @mutex.synchronize do
        @connections.each do |url, conn|
          next unless conn[:ws]
          # Close existing subscriptions
          conn[:subscriptions].each_key do |sub_id|
            conn[:ws].send(JSON.generate(["CLOSE", sub_id])) rescue nil
          end
          conn[:subscriptions].clear
          # Re-subscribe with updated data
          subscribe_all(url, conn[:ws])
        end
      end
      Rails.logger.info("[RelaySubscriptionManager] Refreshed subscriptions on all relays")
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

    # Subscription 2: DMs addressed to us (inbound)
    if owner.nostr_public_key.present?
      sub_id = "dms-in-#{SecureRandom.hex(4)}"
      filter = {
        kinds: [KIND_GIFT_WRAP, KIND_DM, KIND_ENCRYPTED_DM],
        "#p" => [owner.nostr_public_key],
        since: 1.hour.ago.to_i
      }
      ws.send(JSON.generate(["REQ", sub_id, filter]))
      @mutex.synchronize { @connections[url][:subscriptions][sub_id] = :dms }

      # Subscription 2b: DMs authored by us (from other devices)
      sub_id = "dms-out-#{SecureRandom.hex(4)}"
      filter = {
        kinds: [KIND_GIFT_WRAP, KIND_DM, KIND_ENCRYPTED_DM],
        authors: [owner.nostr_public_key],
        since: 1.hour.ago.to_i
      }
      ws.send(JSON.generate(["REQ", sub_id, filter]))
      @mutex.synchronize { @connections[url][:subscriptions][sub_id] = :dms_own }
    end

    # Subscription 3: Profile + presence updates from all known contacts
    # and DM counterparties (not just accepted friends)
    contact_pubkeys = Contact.pluck(:pubkey)
    conversation_pubkeys = Conversation.where.not(counterparty_pubkey: nil).pluck(:counterparty_pubkey)
    all_pubkeys = (contact_pubkeys + conversation_pubkeys).uniq.compact_blank
    all_pubkeys -= [owner.nostr_public_key] # Don't subscribe to our own profile/presence

    if all_pubkeys.any?
      sub_id = "contacts-#{SecureRandom.hex(4)}"
      filter = {
        kinds: [KIND_METADATA, KIND_USER_STATUS],
        authors: all_pubkeys
      }
      ws.send(JSON.generate(["REQ", sub_id, filter]))
      @mutex.synchronize { @connections[url][:subscriptions][sub_id] = :contacts }
    end
  end

  def handle_message(relay_url, raw_data)
    dev_reload! if Rails.env.development?

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

  # Hot-reload changed service/model files in development so the persistent
  # SubscriptionManager picks up code changes without a full server restart.
  DEV_WATCH_FILES = %w[
    app/services/relay_subscription_manager.rb
    app/services/nip44_service.rb
    app/services/nostr_profile_resolver.rb
    app/services/remote_asset_cache.rb
    app/services/nostr_sync_service.rb
    app/models/contact.rb
    app/models/message.rb
    app/models/conversation.rb
  ].freeze

  def dev_reload!
    @dev_mtimes ||= {}
    DEV_WATCH_FILES.each do |relative|
      path = Rails.root.join(relative)
      next unless File.exist?(path)
      mtime = File.mtime(path)
      next if @dev_mtimes[relative] == mtime
      @dev_mtimes[relative] = mtime
      load path
      Rails.logger.info("[RelaySubscriptionManager] Hot-reloaded #{relative}")
    end
  rescue => e
    Rails.logger.warn("[RelaySubscriptionManager] Hot-reload error: #{e.message}")
  end

  def process_inbound_event(event)
    event_id = event["id"]
    return if event_id.blank?

    # Deduplicate — skip events we already have locally
    return if NostrEventLog.already_processed?(event_id)

    kind = event["kind"]
    pubkey = event["pubkey"]

    # For our own events: if already_processed returned false, this is from
    # another device running the same identity — process it normally.
    # (Our own echoes are caught above because outbound logging creates the
    # NostrEventLog entry before the relay echoes the event back.)

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

    # Resolve the sender
    sender_pubkey = event["pubkey"]
    owner = User.owner
    own_event = owner&.nostr_public_key == sender_pubkey

    unless own_event
      contact = Contact.find_or_initialize_by(pubkey: sender_pubkey)
      if contact.new_record? || contact.profile_stale?
        NostrProfileResolver.resolve(sender_pubkey)
        contact.reload if contact.persisted?
      end
    end

    message = channel.messages.create!(
      content: event["content"],
      user: (owner if own_event),
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
    own_event = (sender_pubkey == owner.nostr_public_key)

    # Determine counterparty for decryption key derivation
    if own_event
      # Our event from another device — counterparty is in the "p" tag
      p_tag = (event["tags"] || []).find { |t| t[0] == "p" }
      return unless p_tag
      counterparty_pubkey = p_tag[1]
    else
      counterparty_pubkey = sender_pubkey
    end

    # Decrypt NIP-44 content
    conversation_key = Nip44Service.conversation_key(owner.nostr_private_key, counterparty_pubkey)
    plaintext = Nip44Service.decrypt(event["content"], conversation_key)

    # Try to parse as JSON (structured payload) or treat as plain DM text
    parsed = JSON.parse(plaintext) rescue nil

    if parsed.is_a?(Hash) && parsed["type"] == "friend_request"
      process_friend_request(sender_pubkey, event) unless own_event
    elsif parsed.is_a?(Hash) && parsed["type"] == "friend_response"
      process_friend_response(sender_pubkey, parsed["status"], event) unless own_event
    elsif parsed.is_a?(Hash) && parsed["type"] == "message_edit"
      process_dm_edit(sender_pubkey, parsed, event)
    elsif parsed.is_a?(Hash) && parsed["type"] == "message_delete"
      process_dm_delete(sender_pubkey, parsed, event)
    else
      # Regular DM message
      if own_event
        process_own_dm_message(counterparty_pubkey, plaintext, event)
      else
        process_dm_message(sender_pubkey, plaintext, event)
      end
    end

    NostrEventLog.create!(
      event_id: event["id"],
      kind: event["kind"],
      pubkey: sender_pubkey,
      direction: own_event ? "outbound" : "inbound",
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
      display_name = contact.effective_display_name
      ActionCable.server.broadcast("user_notifications_#{owner.id}", {
        type: "friend_request",
        friendship_id: contact.id,
        from_user: display_name,
        from_user_initial: display_name[0]&.upcase || "?",
        avatar_url: contact.avatar_url.presence || "",
        profile_color: "#b45309"
      })
      # Also notify for pending count update
      ActionCable.server.broadcast("user_notifications_#{owner.id}", {
        type: "friend_update",
        pending_count: Contact.pending_incoming.count
      })
    end

    # Refresh subscriptions to include the new contact's presence
    RelaySubscriptionManager.instance.refresh_subscriptions

    Rails.logger.info("[RelaySubscriptionManager] Incoming friend request from #{sender_pubkey.first(12)}...")
  end

  def process_friend_response(sender_pubkey, status, event)
    contact = Contact.find_by(pubkey: sender_pubkey)
    return unless contact

    owner = User.owner

    case status
    when "accepted"
      contact.update!(friendship_status: :accepted)
      # Publish updated Kind 3 contact list
      NostrPublishJob.perform_later(owner.id, :contacts) if owner
      Rails.logger.info("[RelaySubscriptionManager] Friend request accepted by #{sender_pubkey.first(12)}...")
    when "declined"
      contact.update!(friendship_status: :declined)
      Rails.logger.info("[RelaySubscriptionManager] Friend request declined by #{sender_pubkey.first(12)}...")
    when "removed"
      contact.update!(friendship_status: :not_friend)
      # Update our Kind 3 contact list to reflect removal
      NostrPublishJob.perform_later(owner.id, :contacts) if owner
      Rails.logger.info("[RelaySubscriptionManager] Removed by #{sender_pubkey.first(12)}...")
    end

    # Notify UI to refresh contacts lists
    if owner
      ActionCable.server.broadcast("user_notifications_#{owner.id}", {
        type: "friend_update",
        pending_count: Contact.pending_incoming.count
      })
    end

    # Refresh subscriptions to include the updated contact's presence
    RelaySubscriptionManager.instance.refresh_subscriptions
  end

  def process_dm_message(sender_pubkey, plaintext, event)
    owner = User.owner
    return unless owner

    # Extract content from structured payloads (type: "message" with files/emojis)
    content = plaintext
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
          # Unknown structured payload — log but don't display as a message
          Rails.logger.info("[RelaySubscriptionManager] Ignoring DM payload type=#{parsed["type"]}")
          return
        end
      end
    rescue JSON::ParserError
      # Plain text — use as-is
    end

    # Cache remote file URLs locally so they survive sender going offline
    if files.is_a?(Array) && files.any?
      cached = RemoteAssetCache.cache_all(files)
      cached.each do |remote, local|
        content = content.gsub(remote, local)
      end
    end

    # Replace custom emoji shortcodes with locally-cached inline images
    if emoji_urls.present?
      emoji_urls.each do |name, url|
        cached_url = RemoteAssetCache.cache(url) || url
        img = %(<img src="#{ERB::Util.html_escape(cached_url)}" alt=":#{ERB::Util.html_escape(name)}:" class="inline-block align-text-bottom" style="height:1.375em;width:auto" loading="lazy">)
        content = content.gsub(/:#{Regexp.escape(name)}:/i, img)
      end
    end

    return if content.blank?

    # Find or create conversation by counterparty pubkey
    conversation = Conversation.find_or_create_by_pubkey(owner, sender_pubkey)

    # Create the message
    message = conversation.messages.create!(
      content: content,
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

  # Handle a DM we sent from another device running the same Nostr identity
  def process_own_dm_message(counterparty_pubkey, plaintext, event)
    owner = User.owner
    return unless owner

    # Parse structured payload (same logic as process_dm_message)
    content = plaintext
    emoji_urls = nil
    files = nil
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
          return
        end
      end
    rescue JSON::ParserError
      # Plain text
    end

    # Cache remote files
    if files.is_a?(Array) && files.any?
      cached = RemoteAssetCache.cache_all(files)
      cached.each { |remote, local| content = content.gsub(remote, local) }
    end

    # Replace custom emojis
    if emoji_urls.present?
      emoji_urls.each do |name, url|
        cached_url = RemoteAssetCache.cache(url) || url
        img = %(<img src="#{ERB::Util.html_escape(cached_url)}" alt=":#{ERB::Util.html_escape(name)}:" class="inline-block align-text-bottom" style="height:1.375em;width:auto" loading="lazy">)
        content = content.gsub(/:#{Regexp.escape(name)}:/i, img)
      end
    end

    return if content.blank?

    conversation = Conversation.find_or_create_by_pubkey(owner, counterparty_pubkey)

    message = conversation.messages.create!(
      content: content,
      user: owner,
      public_id: SecureRandom.alphanumeric(12),
      nostr_event_id: event["id"],
      created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
    )

    html = ApplicationController.render(
      partial: "messages/dm_message",
      locals: { message: message }
    )
    ConversationChannel.broadcast_to(conversation, { type: "new_message", html: html })

    Rails.logger.info("[RelaySubscriptionManager] Synced own DM to #{counterparty_pubkey.first(12)}... from another device")
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
