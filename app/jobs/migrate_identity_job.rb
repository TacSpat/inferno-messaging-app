class MigrateIdentityJob < ApplicationJob
  queue_as :default

  KIND_CONTACTS  = 3
  KIND_MUTE_LIST = 10000
  KIND_SERVER_MEMBER = 31753

  def perform(user_id)
    @user = User.find_by(id: user_id)
    return unless @user&.nostr_public_key.present?

    pubkey = @user.nostr_public_key

    # 1. Fetch and import Kind 3 (contact/follow list)
    import_contacts(pubkey)

    # 2. Fetch and import Kind 10000 (mute/block list)
    import_mute_list(pubkey)

    # 3. Rejoin servers from Kind 31753 events
    rejoin_servers(pubkey)

    # 4. Sync DMs and channel history (longer window for migration)
    NostrSyncService.new(@user).sync_all(since: 30.days.ago)

    Rails.logger.info("[MigrateIdentityJob] Migration complete for user #{user_id}")
  end

  private

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
    events = RelayService.fetch_from_all({ kinds: [KIND_SERVER_MEMBER], "#p": [pubkey] })
    return if events.empty?

    # Extract unique group IDs from d-tags
    group_ids = events.map { |e|
      (e["tags"] || []).find { |t| t[0] == "d" }&.dig(1)
    }.compact.uniq

    group_ids.each do |gid|
      next if Server.exists?(nostr_group_id: gid)
      NostrServerJoinJob.perform_later(gid, @user.id)
    rescue => e
      Rails.logger.warn("[MigrateIdentityJob] Server rejoin failed for #{gid}: #{e.message}")
    end

    Rails.logger.info("[MigrateIdentityJob] Queued rejoin for #{group_ids.size} servers")
  rescue => e
    Rails.logger.error("[MigrateIdentityJob] Server rejoin failed: #{e.message}")
  end
end
