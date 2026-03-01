# Pulls historical events from Nostr relays to sync a fresh or
# secondary device running the same identity.
#
# Usage:
#   NostrSyncService.new(user).sync_all(since: 7.days.ago)
#
class NostrSyncService
  def initialize(user)
    @user = user
  end

  # Sync Kind 0 profiles for all contacts
  def sync_contacts
    pubkeys = Contact.pluck(:pubkey)
    return if pubkeys.empty?

    events = RelayService.fetch_from_all({ kinds: [ 0 ], authors: pubkeys })
    # Keep only the latest event per pubkey
    latest = events.group_by { |e| e["pubkey"] }.transform_values { |evts|
      evts.max_by { |e| e["created_at"].to_i }
    }

    latest.each_value do |event|
      contact = Contact.find_by(pubkey: event["pubkey"])
      next unless contact
      metadata = JSON.parse(event["content"]) rescue next
      contact.update_from_metadata(metadata)
    end

    Rails.logger.info("[NostrSyncService] Synced #{latest.size} contact profiles")
  end

  # Sync DM history — both inbound and own outbound from other devices
  def sync_dm_history(since: 7.days.ago)
    pubkey = @user.nostr_public_key
    return if pubkey.blank?

    inbound = RelayService.fetch_from_all({
      kinds: [ 14 ], "#p": [ pubkey ], since: since.to_i
    })
    outbound = RelayService.fetch_from_all({
      kinds: [ 14 ], authors: [ pubkey ], since: since.to_i
    })

    events = (inbound + outbound).uniq { |e| e["id"] }.sort_by { |e| e["created_at"].to_i }
    count = 0

    events.each do |event|
      next if NostrEventLog.already_processed?(event["id"])
      process_synced_dm(event)
      count += 1
    end

    Rails.logger.info("[NostrSyncService] Synced #{count} DM events")
  end

  # Sync group/channel message history
  def sync_group_history(since: 7.days.ago)
    channels = Channel.where.not(nostr_group_id: nil)
    count = 0

    channels.find_each do |channel|
      events = RelayService.fetch_from_all({
        kinds: [ 9 ], "#h": [ channel.nostr_group_id ], since: since.to_i
      })

      events.sort_by { |e| e["created_at"].to_i }.each do |event|
        next if NostrEventLog.already_processed?(event["id"])
        process_synced_group_message(event, channel)
        count += 1
      end
    end

    Rails.logger.info("[NostrSyncService] Synced #{count} group messages")
  end

  def sync_all(since: 7.days.ago)
    sync_contacts
    sync_dm_history(since: since)
    sync_group_history(since: since)
  end

  private

  def process_synced_dm(event)
    manager = RelaySubscriptionManager.instance
    manager.send(:process_dm_event, event)
  rescue => e
    Rails.logger.warn("[NostrSyncService] Failed to process DM #{event["id"]}: #{e.message}")
  end

  def process_synced_group_message(event, channel)
    manager = RelaySubscriptionManager.instance
    manager.send(:process_group_message, event)
  rescue => e
    Rails.logger.warn("[NostrSyncService] Failed to process group message #{event["id"]}: #{e.message}")
  end
end
