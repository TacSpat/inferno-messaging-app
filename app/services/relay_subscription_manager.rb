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

  # Server state event kinds
  KIND_SERVER_METADATA  = 31750
  KIND_SERVER_STRUCTURE = 31751
  KIND_SERVER_ROLES     = 31752
  KIND_SERVER_MEMBER    = 31753
  KIND_SERVER_EMOJIS    = 31754
  KIND_SERVER_STICKERS  = 31755
  KIND_SERVER_BAN       = 31756
  KIND_SERVER_INVITE    = 31757
  KIND_TYPING           = 25050
  KIND_REACTION         = 7

  SERVER_STATE_KINDS = [KIND_SERVER_METADATA, KIND_SERVER_STRUCTURE, KIND_SERVER_ROLES,
                        KIND_SERVER_EMOJIS, KIND_SERVER_STICKERS].freeze
  SERVER_PER_ENTITY_KINDS = [KIND_SERVER_MEMBER, KIND_SERVER_BAN, KIND_SERVER_INVITE].freeze

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
    remote_member_pubkeys = RemoteMember.distinct.pluck(:pubkey)
    all_pubkeys = (contact_pubkeys + conversation_pubkeys + remote_member_pubkeys).uniq.compact_blank
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

    # Subscription 4: Server state events (metadata, structure, roles, emojis, stickers)
    server_group_ids = Server.where.not(nostr_group_id: nil).pluck(:nostr_group_id)
    if server_group_ids.any?
      d_tag_filters = server_group_ids.flat_map { |gid|
        ["inferno-#{gid}", "inferno-struct-#{gid}", "inferno-roles-#{gid}",
         "inferno-emojis-#{gid}", "inferno-stickers-#{gid}"]
      }
      sub_id = "server-state-#{SecureRandom.hex(4)}"
      filter = { kinds: SERVER_STATE_KINDS, "#d" => d_tag_filters }
      ws.send(JSON.generate(["REQ", sub_id, filter]))
      @mutex.synchronize { @connections[url][:subscriptions][sub_id] = :server_state }

      # Subscription 5: Per-member/ban/invite events
      member_d_prefixes = server_group_ids.flat_map { |gid|
        ["inferno-mbr-#{gid}-", "inferno-ban-#{gid}-", "inferno-invite-#{gid}-"]
      }
      # Nostr relays don't support prefix matching on d tags, so we use a broad filter
      # and filter in process_inbound_event. We subscribe to the kinds.
      sub_id = "server-entities-#{SecureRandom.hex(4)}"
      filter = { kinds: SERVER_PER_ENTITY_KINDS, since: 1.hour.ago.to_i }
      ws.send(JSON.generate(["REQ", sub_id, filter]))
      @mutex.synchronize { @connections[url][:subscriptions][sub_id] = :server_entities }

      # Subscription 6: Ephemeral typing for all channels
      all_channel_group_ids = Channel.where.not(nostr_group_id: nil).pluck(:nostr_group_id)
      if all_channel_group_ids.any?
        sub_id = "typing-#{SecureRandom.hex(4)}"
        filter = { kinds: [KIND_TYPING], "#h" => all_channel_group_ids }
        ws.send(JSON.generate(["REQ", sub_id, filter]))
        @mutex.synchronize { @connections[url][:subscriptions][sub_id] = :typing }
      end

      # Subscription 7: Reactions for channel messages
      if all_channel_group_ids.any?
        sub_id = "reactions-#{SecureRandom.hex(4)}"
        filter = { kinds: [KIND_REACTION], "#h" => all_channel_group_ids, since: 1.hour.ago.to_i }
        ws.send(JSON.generate(["REQ", sub_id, filter]))
        @mutex.synchronize { @connections[url][:subscriptions][sub_id] = :reactions }
      end
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
    app/services/nostr_server_auth.rb
    app/services/nostr_server_sync_service.rb
    app/services/voice_token_rpc_service.rb
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
    when KIND_SERVER_METADATA
      process_server_metadata(event)
    when KIND_SERVER_STRUCTURE
      process_server_structure(event)
    when KIND_SERVER_ROLES
      process_server_roles(event)
    when KIND_SERVER_MEMBER
      process_server_member(event)
    when KIND_SERVER_EMOJIS
      process_server_emojis(event)
    when KIND_SERVER_STICKERS
      process_server_stickers(event)
    when KIND_SERVER_BAN
      process_server_ban(event)
    when KIND_SERVER_INVITE
      process_server_invite(event)
    when KIND_TYPING
      process_typing_event(event)
    when KIND_REACTION
      process_reaction_event(event)
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

    # Decrypt NIP-44 encrypted content for encrypted channels
    encrypted_tag = (event["tags"] || []).find { |t| t[0] == "encrypted" && t[1] == "nip44" }
    if encrypted_tag && channel.encrypted? && channel.channel_private_key.present?
      begin
        conversation_key = Nip44Service.conversation_key(channel.channel_private_key, event["pubkey"])
        event["content"] = Nip44Service.decrypt(event["content"], conversation_key)
      rescue Nip44Service::DecryptionError => e
        Rails.logger.warn("[RelaySubscriptionManager] Failed to decrypt encrypted channel message: #{e.message}")
        return
      end
    end

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

      # Auto-create RemoteMember if sender is unknown to this server
      # (the NIP-29 relay has already authorized them as a group member)
      if channel.server
        ensure_remote_member(channel.server, sender_pubkey, contact)
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

    if message
      message_public_id = message.public_id

      # Ensure the original message's event is logged so the history fetcher
      # won't re-import it after deletion
      unless NostrEventLog.exists?(event_id: target_event_id)
        NostrEventLog.create(
          event_id: target_event_id,
          kind: 9,
          pubkey: message.nostr_author_pubkey || message.user&.nostr_public_key || event["pubkey"],
          channel: channel,
          message: message,
          direction: "inbound",
          event_created_at: message.created_at
        )
      end

      message.destroy

      ChannelChatChannel.broadcast_to(channel, {
        type: "delete_message",
        message_id: message_public_id
      })

      Rails.logger.info("[RelaySubscriptionManager] Deleted channel message #{target_event_id}")
    end

    # Log the delete event itself to prevent reprocessing
    NostrEventLog.find_or_create_by(event_id: event["id"]) do |log|
      log.kind = event["kind"]
      log.pubkey = event["pubkey"]
      log.channel = channel
      log.direction = "inbound"
      log.event_created_at = event["created_at"] ? Time.at(event["created_at"]) : Time.current
    end
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
    elsif parsed.is_a?(Hash) && parsed["type"] == "voice_token_request"
      Rails.logger.info("[RelaySubscriptionManager] Received voice_token_request from #{sender_pubkey[0..15]} own=#{own_event}")
      process_voice_token_request(sender_pubkey, parsed, event) unless own_event
      return # Don't log as a DM event
    elsif parsed.is_a?(Hash) && parsed["type"] == "voice_token_response"
      Rails.logger.info("[RelaySubscriptionManager] Received voice_token_response from #{sender_pubkey[0..15]} own=#{own_event} request_id=#{parsed["request_id"]}")
      process_voice_token_response(sender_pubkey, parsed) unless own_event
      return # Don't log as a DM event
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

    # Ensure contact exists with up-to-date profile
    contact = Contact.find_or_initialize_by(pubkey: sender_pubkey)
    if contact.new_record? || contact.profile_stale?
      NostrProfileResolver.resolve(sender_pubkey)
      contact.reload if contact.persisted?
    end

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
    metadata = JSON.parse(event["content"]) rescue nil
    return unless metadata

    contact = Contact.find_or_initialize_by(pubkey: pubkey)
    contact.update_from_metadata(metadata)

    # Also update any remote members with this pubkey and broadcast changes
    RemoteMember.where(pubkey: pubkey).includes(:server).find_each do |rm|
      rm.update_from_metadata(metadata)
      ServerChannel.broadcast_to(rm.server, {
        type: "member_update",
        user_id: rm.public_id,
        html: ApplicationController.render(
          partial: "servers/member_item",
          locals: { member: rm, server: rm.server }
        ),
        display_name: rm.display_name_for,
        username: rm.username,
        tag: rm.tag,
        role_color: rm.role_color_for
      })
    end

    Rails.logger.debug("[RelaySubscriptionManager] Profile update for #{pubkey[0..15]}...")
  end

  # Process NIP-38 Kind 30315 user status events
  def process_presence_event(event)
    pubkey = event["pubkey"]
    contact = Contact.find_by(pubkey: pubkey)

    status_tag = (event["tags"] || []).find { |t| t[0] == "status" }
    state = status_tag&.dig(1) || event["content"]
    return if state.blank?

    if contact
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

    # Update remote members with this pubkey across all servers
    online_state = state == "offline" ? :offline : :online
    remote_members = RemoteMember.where(pubkey: pubkey)
    remote_members.find_each do |rm|
      rm.update_columns(
        online_state: RemoteMember.online_states[online_state],
        last_seen_at: state == "offline" ? nil : Time.current
      )
      ServerChannel.broadcast_to(rm.server, {
        type: "member_update",
        user_id: rm.public_id,
        html: ApplicationController.render(
          partial: "servers/member_item",
          locals: { member: rm.reload, server: rm.server }
        ),
        display_name: rm.display_name_for,
        username: rm.username,
        tag: rm.tag,
        role_color: rm.role_color_for
      })
    end
  end

  # ── Voice Token RPC Handlers ────────────────────────────────────────

  # Provider side: received a token request from a remote user
  def process_voice_token_request(sender_pubkey, data, event)
    server = Server.find_by(public_id: data["server_id"])
    return unless server

    channel = server.channels.find_by(public_id: data["channel_id"])
    return unless channel&.voice?

    # Verify requesting user is a member with voice permission
    user = User.find_by(nostr_public_key: sender_pubkey)
    if user
      membership = server.server_memberships.find_by(user: user)
      unless membership&.has_permission?("connect_voice")
        Rails.logger.warn("[RelaySubscriptionManager] Voice token request denied: #{sender_pubkey[0..15]} lacks connect_voice permission")
        return
      end
    else
      # Check remote membership
      remote = server.remote_members.find_by(pubkey: sender_pubkey)
      unless remote
        Rails.logger.warn("[RelaySubscriptionManager] Voice token request denied: #{sender_pubkey[0..15]} not a member")
        return
      end
    end

    # Find a local provider with LiveKit credentials
    svp = server.server_voice_providers.active.where.not(user_id: nil).includes(:user)
               .find { |s| s.user.livekit_configured? }
    unless svp
      Rails.logger.warn("[RelaySubscriptionManager] Voice token request: no local provider available for #{server.public_id}")
      return
    end

    # Generate token using an OpenStruct for remote user identity
    token_user = OpenStruct.new(
      public_id: data["user_id"] || sender_pubkey[0..15],
      display_name: data["user_display_name"],
      username: data["user_display_name"],
      effective_avatar_url: nil,
      profile_color: nil
    )
    token = LivekitTokenService.generate_token(
      user: token_user, channel: channel, server: server,
      provider: svp.user, skip_permission_check: true
    )

    # Encrypt and publish response
    responder = svp.user
    response_payload = {
      type: "voice_token_response",
      request_id: data["request_id"],
      token: token,
      livekit_url: responder.livekit_url
    }.to_json

    conversation_key = Nip44Service.conversation_key(responder.nostr_private_key, sender_pubkey)
    encrypted = Nip44Service.encrypt(response_payload, conversation_key)

    signer = Nostr::Signer.new(private_key: responder.nostr_private_key)
    resp_event = Nostr::Event.new(
      kind: 14,
      pubkey: responder.nostr_public_key,
      content: encrypted,
      tags: [["p", sender_pubkey]]
    )
    signed = signer.sign(resp_event)
    RelayService.publish_to_all(signed.to_json)

    Rails.logger.info("[RelaySubscriptionManager] Sent voice token response for request #{data["request_id"]} to #{sender_pubkey[0..15]}")
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing voice token request: #{e.message}")
  end

  # Requester side: received a token response from the provider
  def process_voice_token_response(sender_pubkey, data)
    request_id = data["request_id"]
    return if request_id.blank?

    VoiceTokenRpcService.resolve_request(request_id, {
      token: data["token"],
      livekit_url: data["livekit_url"]
    })
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing voice token response: #{e.message}")
  end

  # ── Server State Event Handlers ──────────────────────────────────────

  def find_server_from_event(event)
    tags = event["tags"] || []
    # Try "server" tag first
    server_tag = tags.find { |t| t[0] == "server" }
    gid = server_tag&.dig(1)

    # Fallback: extract from "d" tag
    unless gid
      d_tag = tags.find { |t| t[0] == "d" }
      d_val = d_tag&.dig(1) || ""
      # "inferno-<gid>" or "inferno-struct-<gid>" etc.
      gid = d_val.sub(/\Ainferno-(?:struct-|roles-|emojis-|stickers-|mbr-|ban-|invite-)?/, "")
      # For member/ban/invite, strip the trailing -<pubkey16>
      gid = gid.sub(/-[0-9a-f]{16,}\z/, "") if d_val.match?(/\Ainferno-(?:mbr|ban|invite)-/)
    end

    return nil if gid.blank?
    Server.find_by(nostr_group_id: gid)
  end

  # Auto-create a RemoteMember when a group message arrives from an unknown
  # sender.  The NIP-29 relay has already authorized them as a group member,
  # so we trust that and create the record to make them visible in the sidebar.
  def ensure_remote_member(server, pubkey, contact = nil)
    return if User.exists?(nostr_public_key: pubkey) # Local user — skip
    return if server.remote_members.exists?(pubkey: pubkey) # Already known

    remote = server.remote_members.create!(pubkey: pubkey)

    # Populate from Contact if available
    if contact&.persisted?
      remote.update_from_metadata({
        "display_name" => contact.display_name,
        "name" => contact.display_name,
        "picture" => contact.avatar_url,
        "about" => contact.bio,
        "nip05" => contact.nip05
      })
    end

    # Broadcast new member to sidebar
    ServerChannel.broadcast_to(server, {
      type: "member_join",
      html: ApplicationController.render(
        partial: "servers/member_item",
        locals: { member: remote.reload, server: server }
      ),
      user_id: remote.public_id,
      member_count: server.total_member_count
    })
  rescue ActiveRecord::RecordNotUnique
    # Another thread already created it
  end

  # Fetch Kind 0 profile metadata directly from relays, bypassing Contact model
  def fetch_kind0_metadata(pubkey)
    urls = RelayConnection.active.pluck(:url)
    return nil if urls.empty?

    filter = { kinds: [0], authors: [pubkey], limit: 1 }
    urls.each do |url|
      events = RelayService.fetch_from_relay(url, filter, timeout: 10)
      if events.any?
        event = events.max_by { |e| e["created_at"].to_i }
        begin
          return JSON.parse(event["content"])
        rescue JSON::ParserError
          next
        end
      end
    end
    nil
  rescue => e
    Rails.logger.warn("[RelaySubscriptionManager] Kind 0 fetch failed for #{pubkey[0..15]}: #{e.message}")
    nil
  end

  def broadcast_member_update(member, server)
    ServerChannel.broadcast_to(server, {
      type: "member_update",
      user_id: member.public_id,
      html: ApplicationController.render(
        partial: "servers/member_item",
        locals: { member: member.reload, server: server }
      ),
      display_name: member.display_name_for,
      username: member.username,
      tag: member.tag,
      role_color: member.role_color_for
    })
  rescue => e
    Rails.logger.warn("[RelaySubscriptionManager] broadcast_member_update failed: #{e.message}")
  end

  def log_server_event(event)
    NostrEventLog.create!(
      event_id: event["id"],
      kind: event["kind"],
      pubkey: event["pubkey"],
      direction: "inbound",
      event_created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
    )
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    nil
  end

  # Download an asset URL and attach it to a server's ActiveStorage field.
  # Handles both full URLs (https://host/cached_assets/...) and relative paths.
  def attach_cached_asset(server, field, asset_url)
    return if asset_url.blank?

    # Try local filesystem first (for relative paths or same-instance URLs)
    local_path = if asset_url.start_with?("/cached_assets/")
      Rails.root.join("public", asset_url.delete_prefix("/"))
    elsif asset_url.include?("/cached_assets/")
      filename = asset_url.split("/cached_assets/").last
      Rails.root.join("public", "cached_assets", filename)
    end

    if local_path && File.exist?(local_path)
      attach_from_file(server, field, local_path)
      return
    end

    # Download from remote URL
    if asset_url.start_with?("http")
      cached_path = RemoteAssetCache.cache(asset_url)
      if cached_path
        full_path = Rails.root.join("public", cached_path.delete_prefix("/"))
        attach_from_file(server, field, full_path) if File.exist?(full_path)
      end
    end
  rescue => e
    Rails.logger.warn("[RelaySubscriptionManager] Failed to attach #{field}: #{e.message}")
  end

  def attach_from_file(server, field, path)
    ext = File.extname(path)
    content_type = Rack::Mime.mime_type(ext, "application/octet-stream")
    server.send(field).attach(
      io: File.open(path),
      filename: File.basename(path),
      content_type: content_type
    )
    Rails.logger.info("[RelaySubscriptionManager] Attached #{field} from #{path}")
  end

  # Sync voice provider records from metadata event tags.
  # Creates local providers for users with LiveKit credentials,
  # or remote providers (with provider_pubkey) for unknown pubkeys.
  def sync_voice_providers(server, voice_provider_tags)
    relay_pubkeys = voice_provider_tags.map { |t| t[1] }.compact.uniq
    existing = server.server_voice_providers.includes(:user)
    existing_by_pk = existing.index_by { |svp| svp.provider_pubkey || svp.user&.nostr_public_key }

    # Add new providers
    relay_pubkeys.each do |pubkey|
      next if existing_by_pk[pubkey]
      local_user = User.find_by(nostr_public_key: pubkey)
      if local_user&.livekit_configured?
        server.server_voice_providers.create(user: local_user)
      else
        server.server_voice_providers.create(provider_pubkey: pubkey)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      nil
    end

    # Remove providers no longer in the relay event
    existing_by_pk.each do |pk, svp|
      svp.destroy unless relay_pubkeys.include?(pk)
    end
  end

  def process_server_metadata(event)
    server = find_server_from_event(event)
    return unless server
    return unless NostrServerAuth.authorized_for_event?(server, event)

    tags = event["tags"] || []
    deleted = tags.find { |t| t[0] == "deleted" }&.dig(1) == "true"

    if deleted
      Rails.logger.info("[RelaySubscriptionManager] Server #{server.nostr_group_id} marked deleted via Nostr — destroying locally")
      ServerChannel.broadcast_to(server, { type: "server_deleted" })
      log_server_event(event)
      server.destroy
      return
    end

    name_tag = tags.find { |t| t[0] == "name" }
    about_tag = tags.find { |t| t[0] == "about" }
    welcome_enabled_tag = tags.find { |t| t[0] == "welcome_enabled" }
    welcome_message_tag = tags.find { |t| t[0] == "welcome_message" }
    voice_enabled_tag = tags.find { |t| t[0] == "voice_enabled" }

    attrs = {}
    attrs[:name] = name_tag[1] if name_tag&.dig(1).present?
    attrs[:description] = about_tag[1] if about_tag
    attrs[:welcome_message_enabled] = welcome_enabled_tag[1] == "true" if welcome_enabled_tag
    attrs[:welcome_message_template] = welcome_message_tag[1] if welcome_message_tag
    attrs[:voice_enabled] = voice_enabled_tag[1] == "true" if voice_enabled_tag

    # Download icon/banner and attach via ActiveStorage
    picture_tag = tags.find { |t| t[0] == "picture" }
    if picture_tag&.dig(1).present?
      attach_cached_asset(server, :icon, picture_tag[1])
    end

    banner_tag = tags.find { |t| t[0] == "banner" }
    if banner_tag&.dig(1).present?
      attach_cached_asset(server, :banner, banner_tag[1])
    end

    server.update!(attrs) if attrs.any?

    # Sync voice providers from relay event
    voice_provider_tags = tags.select { |t| t[0] == "voice_provider" }
    sync_voice_providers(server, voice_provider_tags)

    log_server_event(event)

    ServerChannel.broadcast_to(server, { type: "server_updated" })
    Rails.logger.info("[RelaySubscriptionManager] Updated server metadata for #{server.nostr_group_id}")
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing server metadata: #{e.message}")
  end

  def process_server_structure(event)
    server = find_server_from_event(event)
    return unless server
    return unless NostrServerAuth.authorized_for_event?(server, event)

    tags = event["tags"] || []
    cat_tags = tags.select { |t| t[0] == "cat" }
    ch_tags = tags.select { |t| t[0] == "ch" }

    ActiveRecord::Base.transaction do
      # Sync categories
      remote_cat_ids = cat_tags.map { |t| t[1] }
      cat_tags.each do |t|
        # ["cat", public_id, name, position]
        cat = server.categories.find_or_initialize_by(public_id: t[1])
        cat.assign_attributes(name: t[2], position: t[3].to_i)
        cat.save! if cat.changed?
      end
      # Remove categories not in the event
      server.categories.where.not(public_id: remote_cat_ids).each do |cat|
        cat.channels.update_all(category_id: nil)
        cat.destroy
      end

      # Sync channels
      remote_ch_ids = ch_tags.map { |t| t[1] }
      ch_tags.each do |t|
        # ["ch", public_id, name, type, position, cat_id, topic, nsfw, nostr_group_id, perm_overrides, encrypted, channel_public_key]
        ch = server.channels.find_or_initialize_by(public_id: t[1])
        cat = t[5].present? ? server.categories.find_by(public_id: t[5]) : nil
        ch.assign_attributes(
          name: t[2],
          channel_type: t[3],
          position: t[4].to_i,
          category: cat,
          topic: t[6],
          nsfw: t[7] == "true"
        )
        ch.nostr_group_id = t[8] if t[8].present?
        # Sync permissions overrides
        if t[9].present? && t[9] != "{}"
          ch.permissions_overrides = JSON.parse(t[9]) rescue {}
        end
        # Sync encryption fields
        if t[10].present?
          ch.encrypted = t[10] == "true"
          ch.channel_public_key = t[11] if t[11].present?
        end
        ch.save! if ch.changed? || ch.new_record?
      end
      # Remove channels not in the event
      server.channels.where.not(public_id: remote_ch_ids).destroy_all if remote_ch_ids.any?
    end

    log_server_event(event)
    ServerChannel.broadcast_to(server, { type: "sidebar_reorder" })
    Rails.logger.info("[RelaySubscriptionManager] Synced server structure for #{server.nostr_group_id}")
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing server structure: #{e.message}")
  end

  def process_server_roles(event)
    server = find_server_from_event(event)
    return unless server
    return unless NostrServerAuth.authorized_for_event?(server, event)

    tags = event["tags"] || []
    role_tags = tags.select { |t| t[0] == "role" }

    ActiveRecord::Base.transaction do
      remote_role_ids = role_tags.map { |t| t[1] }

      role_tags.each do |t|
        # ["role", public_id, name, color, position, hoist, mentionable, permissions_json]
        role = server.roles.find_or_initialize_by(public_id: t[1])
        perms = JSON.parse(t[7]) rescue {}
        role.assign_attributes(
          name: t[2],
          color: t[3],
          position: t[4].to_i,
          hoist: t[5] == "true",
          permissions: perms
        )
        role.save! if role.changed? || role.new_record?
      end

      # Remove roles not in the event (except system roles we might still need)
      server.roles.where.not(public_id: remote_role_ids).each do |role|
        role.membership_roles.destroy_all
        role.destroy
      end
    end

    log_server_event(event)
    ServerChannel.broadcast_to(server, { type: "roles_updated" })
    Rails.logger.info("[RelaySubscriptionManager] Synced server roles for #{server.nostr_group_id}")
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing server roles: #{e.message}")
  end

  def process_server_member(event)
    server = find_server_from_event(event)
    return unless server
    return unless NostrServerAuth.authorized_for_event?(server, event)

    tags = event["tags"] || []
    p_tag = tags.find { |t| t[0] == "p" }
    return unless p_tag

    member_pubkey = p_tag[1]
    removed = tags.find { |t| t[0] == "removed" }&.dig(1) == "true"

    member_user = User.find_by(nostr_public_key: member_pubkey)

    if removed
      if member_user
        membership = server.server_memberships.find_by(user: member_user)
        membership&.destroy
        ServerChannel.broadcast_to(server, {
          type: "member_leave",
          user_id: member_user.public_id,
          member_count: server.members.count
        })
      else
        remote = server.remote_members.find_by(pubkey: member_pubkey)
        if remote
          remote_public_id = remote.public_id
          remote.destroy
          ServerChannel.broadcast_to(server, {
            type: "member_leave",
            user_id: remote_public_id,
            member_count: server.total_member_count
          })
        end
      end
      log_server_event(event)
      Rails.logger.info("[RelaySubscriptionManager] Member removed from #{server.nostr_group_id}: #{member_pubkey[0..15]}")
      return
    end

    # Create membership if user exists locally
    if member_user
      membership = server.server_memberships.find_or_initialize_by(user: member_user)

      # Update nickname
      nickname_tag = tags.find { |t| t[0] == "nickname" }
      membership.nickname = nickname_tag[1].presence if nickname_tag

      # Update joined_at
      joined_tag = tags.find { |t| t[0] == "joined_at" }
      membership.joined_at = Time.at(joined_tag[1].to_i) if joined_tag&.dig(1).present? && joined_tag[1] != "0"

      is_new = membership.new_record?
      membership.save! if membership.changed? || is_new

      # Sync roles
      roles_tag = tags.find { |t| t[0] == "roles" }
      if roles_tag
        role_public_ids = roles_tag[1..]
        roles = server.roles.where(public_id: role_public_ids)
        membership.roles = roles
      end

      if is_new
        ServerChannel.broadcast_to(server, {
          type: "member_join",
          html: ApplicationController.render(
            partial: "servers/member_item",
            locals: { member: member_user, server: server }
          ),
          user_id: member_user.public_id,
          member_count: server.members.count
        })
      end
    else
      # Remote member — no local User record
      remote = server.remote_members.find_or_initialize_by(pubkey: member_pubkey)

      # Update nickname
      nickname_tag = tags.find { |t| t[0] == "nickname" }
      remote.nickname = nickname_tag[1].presence if nickname_tag

      # Update joined_at
      joined_tag = tags.find { |t| t[0] == "joined_at" }
      remote.joined_at = Time.at(joined_tag[1].to_i) if joined_tag&.dig(1).present? && joined_tag[1] != "0"

      # Update profile from embedded tags (preferred over Kind 0 fetch)
      profile_tags = %w[profile_name profile_display_name profile_picture profile_banner
                        profile_about profile_color profile_color_2 profile_status profile_status_emoji]
      profile_data = profile_tags.each_with_object({}) do |key, h|
        h[key] = tags.find { |t| t[0] == key }&.dig(1)
      end

      if profile_data["profile_name"].present? || profile_data["profile_display_name"].present?
        remote.username = profile_data["profile_name"] if profile_data["profile_name"].present?
        remote.display_name = profile_data["profile_display_name"].presence || profile_data["profile_name"] if profile_data["profile_display_name"].present? || profile_data["profile_name"].present?
        if profile_data["profile_picture"].present?
          remote.avatar_url = profile_data["profile_picture"]
          BlossomCacheJob.perform_later(profile_data["profile_picture"])
        end
        if profile_data["profile_banner"].present?
          remote.banner_url = profile_data["profile_banner"]
          BlossomCacheJob.perform_later(profile_data["profile_banner"])
        end
        remote.bio = profile_data["profile_about"] if profile_data["profile_about"].present?
        remote.profile_color = profile_data["profile_color"] if profile_data["profile_color"].present?
        remote.profile_color_2 = profile_data["profile_color_2"] if profile_data["profile_color_2"].present?
        remote.status = profile_data["profile_status"] if profile_data["profile_status"].present?
        remote.status_emoji = profile_data["profile_status_emoji"] if profile_data["profile_status_emoji"].present?
        remote.profile_fetched_at = Time.current
      end

      is_new = remote.new_record?
      profile_updated = remote.changed?
      remote.save! if profile_updated || is_new

      # Sync roles
      roles_tag = tags.find { |t| t[0] == "roles" }
      if roles_tag
        role_public_ids = roles_tag[1..]
        roles = server.roles.where(public_id: role_public_ids)
        remote.roles = roles
      end

      # Fallback: fetch Kind 0 profile if no profile tags and stale
      has_profile_tags = profile_data["profile_name"].present? || profile_data["profile_display_name"].present?
      if !has_profile_tags && remote.profile_stale?
        fetch_server = server
        Thread.new do
          begin
            metadata = fetch_kind0_metadata(member_pubkey)
            if metadata
              remote.update_from_metadata(metadata)
              broadcast_member_update(remote, fetch_server)
            end
          rescue => e
            Rails.logger.error("[RelaySubscriptionManager] Profile fetch failed for remote member #{member_pubkey[0..15]}: #{e.message}")
          end
        end
      end

      if is_new
        ServerChannel.broadcast_to(server, {
          type: "member_join",
          html: ApplicationController.render(
            partial: "servers/member_item",
            locals: { member: remote, server: server }
          ),
          user_id: remote.public_id,
          member_count: server.total_member_count
        })
      elsif profile_updated
        broadcast_member_update(remote, server)
      end
    end

    log_server_event(event)
    Rails.logger.info("[RelaySubscriptionManager] Synced member for #{server.nostr_group_id}: #{member_pubkey[0..15]}")
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing server member: #{e.message}")
  end

  def process_server_emojis(event)
    server = find_server_from_event(event)
    return unless server
    return unless NostrServerAuth.authorized_for_event?(server, event)

    tags = event["tags"] || []
    emoji_tags = tags.select { |t| t[0] == "emoji" }

    remote_names = emoji_tags.map { |t| t[1] }

    emoji_tags.each do |t|
      # ["emoji", name, blossom_url, creator_pubkey]
      name = t[1]
      url = t[2]
      creator_pubkey = t[3]

      emoji = server.server_emojis.find_or_initialize_by(name: name)
      next unless emoji.new_record? # Don't overwrite existing emojis with attached images

      # Download the image from the Blossom URL
      cached_path = RemoteAssetCache.cache(url)
      if cached_path
        full_path = Rails.root.join("public", cached_path.sub(/\A\//, ""))
        if File.exist?(full_path)
          creator = User.find_by(nostr_public_key: creator_pubkey) || server.owner
          emoji.creator = creator
          emoji.image.attach(
            io: File.open(full_path),
            filename: File.basename(full_path),
            content_type: Marcel::MimeType.for(Pathname.new(full_path))
          )
          emoji.save
        end
      end
    end

    # Remove emojis not in the event
    server.server_emojis.where.not(name: remote_names).destroy_all if remote_names.any?

    log_server_event(event)
    Rails.logger.info("[RelaySubscriptionManager] Synced server emojis for #{server.nostr_group_id}")
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing server emojis: #{e.message}")
  end

  def process_server_stickers(event)
    server = find_server_from_event(event)
    return unless server
    return unless NostrServerAuth.authorized_for_event?(server, event)

    tags = event["tags"] || []
    sticker_tags = tags.select { |t| t[0] == "sticker" }

    remote_names = sticker_tags.map { |t| t[1] }

    sticker_tags.each do |t|
      # ["sticker", name, description, blossom_url, creator_pubkey]
      name = t[1]
      description = t[2]
      url = t[3]
      creator_pubkey = t[4]

      sticker = server.server_stickers.find_or_initialize_by(name: name)
      next unless sticker.new_record?

      cached_path = RemoteAssetCache.cache(url)
      if cached_path
        full_path = Rails.root.join("public", cached_path.sub(/\A\//, ""))
        if File.exist?(full_path)
          creator = User.find_by(nostr_public_key: creator_pubkey) || server.owner
          sticker.creator = creator
          sticker.description = description
          sticker.image.attach(
            io: File.open(full_path),
            filename: File.basename(full_path),
            content_type: Marcel::MimeType.for(Pathname.new(full_path))
          )
          sticker.save
        end
      end
    end

    server.server_stickers.where.not(name: remote_names).destroy_all if remote_names.any?

    log_server_event(event)
    Rails.logger.info("[RelaySubscriptionManager] Synced server stickers for #{server.nostr_group_id}")
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing server stickers: #{e.message}")
  end

  def process_server_ban(event)
    server = find_server_from_event(event)
    return unless server
    return unless NostrServerAuth.authorized_for_event?(server, event)

    tags = event["tags"] || []
    p_tag = tags.find { |t| t[0] == "p" }
    return unless p_tag

    banned_pubkey = p_tag[1]
    unbanned = tags.find { |t| t[0] == "unbanned" }&.dig(1) == "true"

    banned_user = User.find_by(nostr_public_key: banned_pubkey)
    return unless banned_user

    if unbanned
      server.bans.where(user: banned_user).destroy_all
      Rails.logger.info("[RelaySubscriptionManager] Unbanned #{banned_pubkey[0..15]} from #{server.nostr_group_id}")
    else
      reason_tag = tags.find { |t| t[0] == "reason" }
      banned_by_tag = tags.find { |t| t[0] == "banned_by" }
      banned_by = User.find_by(nostr_public_key: banned_by_tag&.dig(1)) || server.owner

      ban = server.bans.find_or_initialize_by(user: banned_user)
      ban.banned_by = banned_by
      ban.reason = reason_tag&.dig(1)
      ban.save!
      Rails.logger.info("[RelaySubscriptionManager] Banned #{banned_pubkey[0..15]} from #{server.nostr_group_id}")
    end

    log_server_event(event)
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing server ban: #{e.message}")
  end

  def process_server_invite(event)
    server = find_server_from_event(event)
    return unless server
    return unless NostrServerAuth.authorized_for_event?(server, event)

    tags = event["tags"] || []
    code_tag = tags.find { |t| t[0] == "code" }
    return unless code_tag

    code = code_tag[1]
    revoked = tags.find { |t| t[0] == "revoked" }&.dig(1) == "true"

    if revoked
      invite = server.invites.find_by(code: code)
      invite&.update!(active: false)
      Rails.logger.info("[RelaySubscriptionManager] Revoked invite #{code} for #{server.nostr_group_id}")
    else
      invite = server.invites.find_or_initialize_by(code: code)
      if invite.new_record?
        max_uses_tag = tags.find { |t| t[0] == "max_uses" }
        expires_tag = tags.find { |t| t[0] == "expires_at" }
        created_by_tag = tags.find { |t| t[0] == "created_by" }
        uses_tag = tags.find { |t| t[0] == "uses" }

        creator = User.find_by(nostr_public_key: created_by_tag&.dig(1)) || server.owner
        invite.creator = creator
        invite.max_uses = max_uses_tag&.dig(1)&.to_i
        expires_val = expires_tag&.dig(1)&.to_i
        invite.expires_at = expires_val && expires_val > 0 ? Time.at(expires_val) : nil
        invite.uses_count = uses_tag&.dig(1)&.to_i || 0
        invite.save!
        Rails.logger.info("[RelaySubscriptionManager] Created invite #{code} for #{server.nostr_group_id}")
      end
    end

    log_server_event(event)
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue => e
    Rails.logger.error("[RelaySubscriptionManager] Error processing server invite: #{e.message}")
  end

  def process_typing_event(event)
    # Ephemeral — no dedup needed, no logging
    owner = User.owner
    return unless owner
    return if event["pubkey"] == owner.nostr_public_key # Skip our own typing

    tags = event["tags"] || []
    h_tag = tags.find { |t| t[0] == "h" }
    return unless h_tag

    channel = Channel.find_by(nostr_group_id: h_tag[1])
    return unless channel

    parsed = JSON.parse(event["content"]) rescue {}
    username = parsed["username"] || event["pubkey"][0..11] + "..."
    avatar_info = {}
    avatar_info[:avatar_url] = parsed["avatar_url"] if parsed["avatar_url"].present?
    avatar_info[:avatar_initial] = parsed["avatar_initial"] if parsed["avatar_initial"].present?
    avatar_info[:avatar_color] = parsed["avatar_color"] if parsed["avatar_color"].present?

    ChannelChatChannel.broadcast_to(channel, {
      type: "typing",
      user_id: "nostr-#{event["pubkey"][0..15]}",
      username: username
    }.merge(avatar_info))
  rescue => e
    Rails.logger.warn("[RelaySubscriptionManager] Error processing typing event: #{e.message}")
  end

  def process_reaction_event(event)
    owner = User.owner
    return unless owner

    tags = event["tags"] || []
    e_tag = tags.find { |t| t[0] == "e" }
    h_tag = tags.find { |t| t[0] == "h" }
    return unless e_tag && h_tag

    target_event_id = e_tag[1]
    channel = Channel.find_by(nostr_group_id: h_tag[1])
    return unless channel

    message = Message.find_by(nostr_event_id: target_event_id, channel: channel)
    return unless message

    emoji = event["content"]
    reactor_pubkey = event["pubkey"]

    # Find or create a local user proxy for the reactor
    reactor_user = User.find_by(nostr_public_key: reactor_pubkey)

    if emoji == "-"
      # Remove reaction
      if reactor_user
        message.reactions.where(user: reactor_user).destroy_all
      end
    else
      return if emoji.blank?
      if reactor_user
        message.reactions.find_or_create_by!(user: reactor_user, emoji: emoji)
      end
    end

    # Broadcast updated reactions
    html = ApplicationController.render(
      partial: "messages/reactions",
      locals: { message: message.reload, reaction_controller: "message-form" }
    )
    ChannelChatChannel.broadcast_to(channel, {
      type: "update_reactions",
      message_id: message.public_id,
      html: html
    })

    log_server_event(event)
    Rails.logger.debug("[RelaySubscriptionManager] Processed reaction from #{reactor_pubkey[0..15]} on #{target_event_id[0..15]}")
  rescue ActiveRecord::RecordNotUnique
    nil
  rescue => e
    Rails.logger.warn("[RelaySubscriptionManager] Error processing reaction event: #{e.message}")
  end

  # ── Connection Management ──────────────────────────────────────────

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
