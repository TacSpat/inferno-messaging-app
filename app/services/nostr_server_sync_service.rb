# Bootstraps a server from Nostr relay state. Used when joining a server
# for the first time on a fresh instance, or syncing latest state on login.
#
# Usage:
#   NostrServerSyncService.new("inferno-abc123", joining_user: user).sync_all
#
class NostrServerSyncService
  def initialize(server_nostr_group_id, joining_user: nil)
    @gid = server_nostr_group_id
    @user = joining_user
  end

  # Fetch just Kind 31750 metadata for preview display (no DB writes).
  # Returns a hash: { name:, about:, picture_url:, owner_pubkey:, member_count: }
  def self.fetch_metadata_preview(nostr_group_id)
    events = RelayService.fetch_from_all({
      kinds: [ RelaySubscriptionManager::KIND_SERVER_METADATA ],
      "#d" => [ "inferno-#{nostr_group_id}" ]
    })
    event = events.max_by { |e| e["created_at"].to_i } if events.any?
    return nil unless event

    tags = event["tags"] || []
    info = {
      name: tag_value(tags, "name"),
      about: tag_value(tags, "about"),
      picture_url: tag_value(tags, "picture"),
      banner_url: tag_value(tags, "banner"),
      owner_pubkey: tag_value(tags, "owner"),
      discoverable: tag_value(tags, "discoverable") == "true"
    }

    # Optionally count members from Kind 31753 events
    member_events = RelayService.fetch_from_all({
      kinds: [ RelaySubscriptionManager::KIND_SERVER_MEMBER ]
    })
    members = member_events.select { |e|
      d_tag = (e["tags"] || []).find { |t| t[0] == "d" }
      d_val = d_tag&.dig(1) || ""
      d_val.start_with?("inferno-mbr-#{nostr_group_id}-")
    }
    # Deduplicate by d-tag and exclude removed members
    grouped = members.group_by { |e| (e["tags"] || []).find { |t| t[0] == "d" }&.dig(1) }
    active_count = grouped.count { |_d, evts|
      latest = evts.max_by { |e| e["created_at"].to_i }
      !(latest["tags"] || []).any? { |t| t[0] == "removed" && t[1] == "true" }
    }
    info[:member_count] = active_count

    info
  rescue => e
    Rails.logger.warn("[NostrServerSyncService] fetch_metadata_preview failed: #{e.message}")
    nil
  end

  def self.tag_value(tags, key)
    tags.find { |t| t[0] == key }&.dig(1)
  end
  private_class_method :tag_value

  def sync_all
    sync_metadata
    sync_structure
    sync_roles
    sync_members
    sync_emojis
    sync_stickers
    sync_bans
    sync_invites
    sync_pins
    Rails.logger.info("[NostrServerSyncService] Full sync complete for #{@gid}")
  end

  # Sync only server-level metadata and structure (lighter than full sync)
  def sync_state
    sync_metadata
    sync_structure
    sync_roles
  end

  # Public: re-sync just members (idempotent, safe to call anytime)
  def resync_members
    sync_members
  end

  private

  def sync_metadata
    events = fetch_events(RelaySubscriptionManager::KIND_SERVER_METADATA, "inferno-#{@gid}")
    event = latest_event(events)
    return unless event

    # Bootstrap: create the server record if it doesn't exist locally.
    # Use insert to skip after_create callbacks (create_defaults, assign_nostr_group_id)
    # since the relay data provides the real channels, roles, etc.
    unless Server.exists?(nostr_group_id: @gid)
      tags = event["tags"] || []
      name = tags.find { |t| t[0] == "name" }&.dig(1) || "Unknown Server"
      owner_pubkey = tags.find { |t| t[0] == "owner" }&.dig(1)
      owner = User.find_by(nostr_public_key: owner_pubkey) if owner_pubkey.present?
      owner ||= @user || User.first

      Server.insert({
        public_id: SecureRandom.alphanumeric(12),
        name: name,
        nostr_group_id: @gid,
        owner_id: owner.id,
        created_at: Time.current,
        updated_at: Time.current
      })
      Rails.logger.info("[NostrServerSyncService] Created server record for #{@gid} (#{name})")
    end

    process_via_manager(:process_server_metadata, event)
    Rails.logger.info("[NostrServerSyncService] Synced metadata for #{@gid}")
  end

  def sync_structure
    events = fetch_events(RelaySubscriptionManager::KIND_SERVER_STRUCTURE, "inferno-struct-#{@gid}")
    event = latest_event(events)
    return unless event

    process_via_manager(:process_server_structure, event)
    Rails.logger.info("[NostrServerSyncService] Synced structure for #{@gid}")
  end

  def sync_roles
    events = fetch_events(RelaySubscriptionManager::KIND_SERVER_ROLES, "inferno-roles-#{@gid}")
    event = latest_event(events)
    return unless event

    process_via_manager(:process_server_roles, event)
    Rails.logger.info("[NostrServerSyncService] Synced roles for #{@gid}")
  end

  def sync_members
    # Member events are per-member, so we fetch all with prefix matching
    events = RelayService.fetch_from_all({
      kinds: [ RelaySubscriptionManager::KIND_SERVER_MEMBER ]
    })

    # Filter to our server's member events
    member_events = events.select { |e|
      d_tag = (e["tags"] || []).find { |t| t[0] == "d" }
      d_val = d_tag&.dig(1) || ""
      d_val.start_with?("inferno-mbr-#{@gid}-")
    }

    # Group by d-tag and take latest per member
    grouped = member_events.group_by { |e|
      (e["tags"] || []).find { |t| t[0] == "d" }&.dig(1)
    }

    count = 0
    grouped.each_value do |evts|
      event = evts.max_by { |e| e["created_at"].to_i }
      # Skip already_processed? check — member processing is idempotent
      # (uses find_or_initialize_by) and we need to backfill RemoteMembers
      # for events logged before the RemoteMember feature existed.
      process_via_manager(:process_server_member, event)
      count += 1
    end

    Rails.logger.info("[NostrServerSyncService] Synced #{count} members for #{@gid}")
  end

  def sync_emojis
    events = fetch_events(RelaySubscriptionManager::KIND_SERVER_EMOJIS, "inferno-emojis-#{@gid}")
    event = latest_event(events)
    return unless event

    process_via_manager(:process_server_emojis, event)
    Rails.logger.info("[NostrServerSyncService] Synced emojis for #{@gid}")
  end

  def sync_stickers
    events = fetch_events(RelaySubscriptionManager::KIND_SERVER_STICKERS, "inferno-stickers-#{@gid}")
    event = latest_event(events)
    return unless event

    process_via_manager(:process_server_stickers, event)
    Rails.logger.info("[NostrServerSyncService] Synced stickers for #{@gid}")
  end

  def sync_bans
    events = RelayService.fetch_from_all({
      kinds: [ RelaySubscriptionManager::KIND_SERVER_BAN ]
    })

    ban_events = events.select { |e|
      d_tag = (e["tags"] || []).find { |t| t[0] == "d" }
      d_val = d_tag&.dig(1) || ""
      d_val.start_with?("inferno-ban-#{@gid}-")
    }

    grouped = ban_events.group_by { |e|
      (e["tags"] || []).find { |t| t[0] == "d" }&.dig(1)
    }

    count = 0
    grouped.each_value do |evts|
      event = evts.max_by { |e| e["created_at"].to_i }
      next if NostrEventLog.already_processed?(event["id"])
      process_via_manager(:process_server_ban, event)
      count += 1
    end

    Rails.logger.info("[NostrServerSyncService] Synced #{count} bans for #{@gid}")
  end

  def sync_invites
    events = RelayService.fetch_from_all({
      kinds: [ RelaySubscriptionManager::KIND_SERVER_INVITE ]
    })

    invite_events = events.select { |e|
      d_tag = (e["tags"] || []).find { |t| t[0] == "d" }
      d_val = d_tag&.dig(1) || ""
      d_val.start_with?("inferno-invite-#{@gid}-")
    }

    grouped = invite_events.group_by { |e|
      (e["tags"] || []).find { |t| t[0] == "d" }&.dig(1)
    }

    count = 0
    grouped.each_value do |evts|
      event = evts.max_by { |e| e["created_at"].to_i }
      next if NostrEventLog.already_processed?(event["id"])
      process_via_manager(:process_server_invite, event)
      count += 1
    end

    Rails.logger.info("[NostrServerSyncService] Synced #{count} invites for #{@gid}")
  end

  def sync_pins
    server = Server.find_by(nostr_group_id: @gid)
    return unless server

    # Fetch all Kind 9006 pin events for this server's channels
    group_ids = server.channels.where.not(nostr_group_id: nil).pluck(:nostr_group_id)
    return if group_ids.empty?

    events = RelayService.fetch_from_all({
      kinds: [RelaySubscriptionManager::NIP29_PIN_MESSAGE],
      "#h" => group_ids
    })

    # Group by target event ID (e tag), take latest pin state per message
    grouped = events.group_by { |e|
      (e["tags"] || []).find { |t| t[0] == "e" }&.dig(1)
    }.compact

    # Reset all pins first — relay is authoritative
    Message.where(channel: server.channels, pinned: true).update_all(pinned: false)

    count = 0
    grouped.each do |target_event_id, pin_events|
      next if target_event_id.blank?
      latest = pin_events.max_by { |e| e["created_at"].to_i }
      pinned_tag = (latest["tags"] || []).find { |t| t[0] == "pinned" }
      pinned = pinned_tag && pinned_tag[1] == "true"

      if pinned
        message = Message.find_by(nostr_event_id: target_event_id)
        if message
          message.update_columns(pinned: true)
          count += 1
        end
      end
    end

    Rails.logger.info("[NostrServerSyncService] Synced #{count} pins for #{@gid}")
  end

  # Fetch events for a single replaceable event (one d-tag value)
  def fetch_events(kind, d_tag)
    RelayService.fetch_from_all({ kinds: [ kind ], "#d" => [ d_tag ] })
  end

  # Pick the latest event by created_at (last-write-wins)
  def latest_event(events)
    return nil if events.empty?
    event = events.max_by { |e| e["created_at"].to_i }
    return nil if NostrEventLog.already_processed?(event["id"])
    event
  end

  # Delegate processing to RelaySubscriptionManager's existing handlers.
  # Skip auth during bootstrap — we trust relay events for initial sync.
  def process_via_manager(method, event)
    Thread.current[:nostr_skip_auth] = true
    manager = RelaySubscriptionManager.instance
    manager.send(method, event)
  rescue => e
    Rails.logger.warn("[NostrServerSyncService] Failed to process #{method}: #{e.message}")
  ensure
    Thread.current[:nostr_skip_auth] = false
  end
end
