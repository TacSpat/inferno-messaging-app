class NostrSyncJob < ApplicationJob
  queue_as :default

  def perform(user_id, since_hours: 168) # 7 days default
    user = User.find(user_id)
    NostrSyncService.new(user).sync_all(since: since_hours.hours.ago)
  end
end
