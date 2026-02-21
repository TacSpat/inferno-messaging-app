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
      kinds: [RelaySubscriptionManager::KIND_SERVER_METADATA],
      "#d" => ["inferno-#{nostr_group_id}"]
    })
    event = events.max_by { |e| e["created_at"].to_i } if events.any?
    return nil unless event

    tags = event["tags"] || []
    info = {
      name: tag_value(tags, "name"),
      about: tag_value(tags, "about"),
      picture_url: tag_value(tags, "picture"),
      banner_url: tag_value(tags, "banner"),
      owner_pubkey: tag_value(tags, "owner")
    }

    # Optionally count members from Kind 31753 events
    member_events = RelayService.fetch_from_all({
      kinds: [RelaySubscriptionManager::KIND_SERVER_MEMBER]
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
    Rails.logger.info("[NostrServerSyncService] Full sync complete for #{@gid}")
  end

  # Sync only server-level metadata and structure (lighter than full sync)
  def sync_state
    sync_metadata
    sync_structure
    sync_roles
  end

  private

  def sync_metadata
    events = fetch_events(RelaySubscriptionManager::KIND_SERVER_METADATA, "inferno-#{@gid}")
    event = latest_event(events)
    return unless event

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
      kinds: [RelaySubscriptionManager::KIND_SERVER_MEMBER]
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
      next if NostrEventLog.already_processed?(event["id"])
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
      kinds: [RelaySubscriptionManager::KIND_SERVER_BAN]
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
      kinds: [RelaySubscriptionManager::KIND_SERVER_INVITE]
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

  # Fetch events for a single replaceable event (one d-tag value)
  def fetch_events(kind, d_tag)
    RelayService.fetch_from_all({ kinds: [kind], "#d" => [d_tag] })
  end

  # Pick the latest event by created_at (last-write-wins)
  def latest_event(events)
    return nil if events.empty?
    event = events.max_by { |e| e["created_at"].to_i }
    return nil if NostrEventLog.already_processed?(event["id"])
    event
  end

  # Delegate processing to RelaySubscriptionManager's existing handlers
  def process_via_manager(method, event)
    manager = RelaySubscriptionManager.instance
    manager.send(method, event)
  rescue => e
    Rails.logger.warn("[NostrServerSyncService] Failed to process #{method}: #{e.message}")
  end
end
