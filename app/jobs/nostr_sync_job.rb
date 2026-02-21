class NostrSyncJob < ApplicationJob
  queue_as :default

  def perform(user_id, since_hours: 168) # 7 days default
    user = User.find(user_id)
    NostrSyncService.new(user).sync_all(since: since_hours.hours.ago)

    # Also sync server state for all joined servers
    user.servers.find_each do |server|
      next unless server.nostr_group_id.present?
      NostrServerSyncService.new(server.nostr_group_id, joining_user: user).sync_state
    rescue => e
      Rails.logger.warn("[NostrSyncJob] Failed to sync server #{server.nostr_group_id}: #{e.message}")
    end
  end
end
