class MigrateIdentityJob < ApplicationJob
  queue_as :default

  KIND_CONTACTS  = 3
  KIND_MUTE_LIST = 10000
  KIND_SERVER_MEMBER = 31753

  def perform(user_id)
    @user = User.find_by(id: user_id)
    return unless @user&.nostr_public_key.present?

    @cache_key = "migrate_identity:#{user_id}"
    pubkey = @user.nostr_public_key

    # 1. Fetch and import contacts
    update_progress("contacts", 10)
    import_contacts(pubkey)

    # 2. Fetch and import mute/block list
    update_progress("blocks", 25)
    import_mute_list(pubkey)

    # 3. Rejoin servers
    update_progress("servers", 40)
    server_count = rejoin_servers(pubkey)

    # 4. Sync contact profiles
    update_progress("profiles", 55)
    NostrSyncService.new(@user).sync_contacts

    # 5. Sync DM history (without rendering — no request context in jobs)
    update_progress("messages", 70)
    sync_dm_history_raw(pubkey)

    # 6. Sync channel/group history
    update_progress("channels", 85)
    NostrSyncService.new(@user).sync_group_history(since: 30.days.ago)

    # 7. Wait briefly for server join jobs to finish
    if server_count > 0
      update_progress("servers_finishing", 95)
      wait_for_server_joins(server_count)
    end

    update_progress("complete", 100)
    broadcast_migration_complete
    Rails.logger.info("[MigrateIdentityJob] Migration complete for user #{user_id}")
  rescue => e
    Rails.logger.error("[MigrateIdentityJob] Failed: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
    update_progress("failed", 0, error: e.message)
  end

  private

  def update_progress(step, progress, error: nil)
    data = { step: step, progress: progress }
    data[:error] = error if error
    Rails.cache.write(@cache_key, data, expires_in: 5.minutes)
    broadcast_data = data.dup
    broadcast_data[:redirect_url] = Rails.application.routes.url_helpers.authenticated_root_path if step == "complete"
    MigrationChannel.broadcast_to(@user, broadcast_data)
  end

  def broadcast_migration_complete
    ActionCable.server.broadcast(
      "user_notifications_#{@user.id}",
      { type: "migration_complete" }
    )
  end

  def import_contacts(pubkey)
    events = RelayService.fetch_from_all({ kinds: [KIND_CONTACTS], authors: [pubkey], limit: 1 })
    return if events.empty?

    newest = events.max_by { |e| e["created_at"].to_i }
    tags = newest["tags"] || []
    contact_pubkeys = tags.select { |t| t[0] == "p" }.map { |t| t[1] }.uniq

    contact_pubkeys.each do |pk|
      next if pk == pubkey # skip self
      contact = Contact.find_or_initialize_by(pubkey: pk)
      contact.friendship_status = :accepted unless contact.blocked?
      contact.save!
    end

    Rails.logger.info("[MigrateIdentityJob] Imported #{contact_pubkeys.size} contacts from Kind 3")

    # Resolve profiles for imported contacts
    NostrProfileResolver.resolve_batch(contact_pubkeys)
  rescue => e
    Rails.logger.error("[MigrateIdentityJob] Contact import failed: #{e.message}")
  end

  def import_mute_list(pubkey)
    events = RelayService.fetch_from_all({ kinds: [KIND_MUTE_LIST], authors: [pubkey], limit: 1 })
    return if events.empty?

    newest = events.max_by { |e| e["created_at"].to_i }
    tags = newest["tags"] || []
    muted_pubkeys = tags.select { |t| t[0] == "p" }.map { |t| t[1] }.uniq

    muted_pubkeys.each do |pk|
      contact = Contact.find_or_initialize_by(pubkey: pk)
      contact.update!(friendship_status: :blocked)
    end

    Rails.logger.info("[MigrateIdentityJob] Imported #{muted_pubkeys.size} blocks from Kind 10000")
  rescue => e
    Rails.logger.error("[MigrateIdentityJob] Mute list import failed: #{e.message}")
  end

  def rejoin_servers(pubkey)
    # Try two strategies: events where user is tagged as member, and events authored by user (self-join)
    events_by_tag = RelayService.fetch_from_all({ kinds: [KIND_SERVER_MEMBER], "#p": [pubkey] })
    events_by_author = RelayService.fetch_from_all({ kinds: [KIND_SERVER_MEMBER], authors: [pubkey] })
    events = (events_by_tag + events_by_author).uniq { |e| e["id"] }

    Rails.logger.info("[MigrateIdentityJob] Found #{events_by_tag.size} member events by #p tag, #{events_by_author.size} by author, #{events.size} total unique")

    return 0 if events.empty?

    # Filter out "removed" events and extract server group IDs from "server" tag
    active_events = events.reject { |e|
      (e["tags"] || []).any? { |t| t[0] == "removed" }
    }

    group_ids = active_events.map { |e|
      (e["tags"] || []).find { |t| t[0] == "server" }&.dig(1)
    }.compact.uniq

    Rails.logger.info("[MigrateIdentityJob] Server group IDs to rejoin: #{group_ids.inspect}")

    group_ids.each do |gid|
      next if Server.exists?(nostr_group_id: gid)
      Rails.logger.info("[MigrateIdentityJob] Joining server #{gid}...")
      NostrServerJoinJob.perform_now(gid, @user.id)
    rescue => e
      Rails.logger.warn("[MigrateIdentityJob] Server rejoin failed for #{gid}: #{e.message}")
    end

    Rails.logger.info("[MigrateIdentityJob] Joined #{group_ids.size} servers")
    group_ids.size
  rescue => e
    Rails.logger.error("[MigrateIdentityJob] Server rejoin failed: #{e.message}")
    0
  end

  # Process DMs directly without ApplicationController.render (no Warden in jobs)
  def sync_dm_history_raw(pubkey)
    since = 30.days.ago
    owner = @user

    inbound = RelayService.fetch_from_all({
      kinds: [14], "#p": [pubkey], since: since.to_i
    })
    outbound = RelayService.fetch_from_all({
      kinds: [14], authors: [pubkey], since: since.to_i
    })

    events = (inbound + outbound).uniq { |e| e["id"] }.sort_by { |e| e["created_at"].to_i }
    count = 0

    events.each do |event|
      next if NostrEventLog.already_processed?(event["id"])
      process_dm_for_migration(event, owner)
      count += 1
    rescue => e
      Rails.logger.warn("[MigrateIdentityJob] Failed to process DM #{event["id"]}: #{e.message}")
    end

    Rails.logger.info("[MigrateIdentityJob] Synced #{count} DM events")
  rescue => e
    Rails.logger.error("[MigrateIdentityJob] DM sync failed: #{e.message}")
  end

  def process_dm_for_migration(event, owner)
    return unless owner.nostr_private_key.present?

    sender_pubkey = event["pubkey"]
    own_event = (sender_pubkey == owner.nostr_public_key)

    # Skip DMs from blocked contacts
    return if !own_event && Contact.blocked_contacts.exists?(pubkey: sender_pubkey)

    # Determine counterparty
    if own_event
      p_tag = (event["tags"] || []).find { |t| t[0] == "p" }
      return unless p_tag
      counterparty_pubkey = p_tag[1]
    else
      counterparty_pubkey = sender_pubkey
    end

    # Decrypt NIP-44
    conversation_key = Nip44Service.conversation_key(owner.nostr_private_key, counterparty_pubkey)
    plaintext = Nip44Service.decrypt(event["content"], conversation_key)

    parsed = JSON.parse(plaintext) rescue nil

    # Handle message deletions
    if parsed.is_a?(Hash) && parsed["type"] == "message_delete" && parsed["event_id"].present?
      conversation = Conversation.find_or_create_by_pubkey(owner, counterparty_pubkey)
      msg = conversation.messages.find_by(nostr_event_id: parsed["event_id"])
      msg&.destroy
      # Mark as processed so we don't re-import the original message
      NostrEventLog.find_or_create_by(event_id: parsed["event_id"])
      return
    end

    # Handle message edits
    if parsed.is_a?(Hash) && parsed["type"] == "message_edit" && parsed["event_id"].present?
      msg = Message.find_by(nostr_event_id: parsed["event_id"])
      msg&.update!(content: parsed["content"], edited_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current)
      return
    end

    # Skip non-message payloads (friend requests, voice tokens, etc.)
    if parsed.is_a?(Hash) && parsed.key?("type") && parsed["type"] != "message"
      return
    end

    # Extract message content
    content = plaintext
    files = nil
    if parsed.is_a?(Hash) && parsed["type"] == "message"
      content = parsed["content"] || ""
      files = parsed["files"]
      if files.is_a?(Array) && files.any?
        # Cache remote file URLs locally; drop files that fail to download
        cached = RemoteAssetCache.cache_all(files)
        resolved = files.filter_map { |url| cached[url] || (url.match?(%r{/rails/active_storage/}) ? nil : url) }
        if resolved.any?
          content += "\n" unless content.empty?
          content += resolved.join("\n")
        end
      end
    end

    return if content.blank?

    # Ensure contact exists
    unless own_event
      Contact.find_or_create_by!(pubkey: sender_pubkey)
    end

    # Find or create conversation
    conversation = Conversation.find_or_create_by_pubkey(owner, counterparty_pubkey)

    # Create the message (skip if already exists by nostr_event_id)
    return if conversation.messages.exists?(nostr_event_id: event["id"])

    msg_attrs = {
      content: content,
      public_id: SecureRandom.alphanumeric(12),
      nostr_event_id: event["id"],
      created_at: event["created_at"] ? Time.at(event["created_at"]) : Time.current
    }

    if own_event
      msg_attrs[:user] = owner
    else
      msg_attrs[:nostr_author_pubkey] = sender_pubkey
    end

    conversation.messages.create!(msg_attrs)

  end

  def wait_for_server_joins(count)
    # Poll for up to 30 seconds for server joins to complete
    15.times do
      joined = @user.servers.count
      break if joined >= count
      sleep 2
    end
  end
end
