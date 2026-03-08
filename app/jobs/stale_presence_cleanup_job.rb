class StalePresenceCleanupJob < ApplicationJob
  queue_as :default

  # Periodically mark remote members and contacts as offline if their
  # last_seen_at has gone stale. This handles instances that crash
  # without sending an "offline" Nostr presence event.
  def perform
    cutoff = RemoteMember::PRESENCE_STALE_AFTER.ago

    # Mark stale remote members as offline and broadcast the change
    stale_remote = RemoteMember.where.not(online_state: :offline)
                               .where("last_seen_at IS NULL OR last_seen_at < ?", cutoff)

    stale_remote.find_each do |rm|
      rm.update_columns(online_state: RemoteMember.online_states[:offline])
      ServerChannel.broadcast_to(rm.server, {
        type: "presence",
        user_id: rm.public_id,
        state: "offline"
      })
    end

    # Mark stale contacts' last_seen_at as nil so Contact#online? returns false
    Contact.where.not(last_seen_at: nil)
           .where("last_seen_at < ?", cutoff)
           .update_all(last_seen_at: nil)

    # Re-enqueue self to run again in 2 minutes
    self.class.set(wait: 2.minutes).perform_later
  end
end
