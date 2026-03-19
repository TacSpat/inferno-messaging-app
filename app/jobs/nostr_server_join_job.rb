class NostrServerJoinJob < ApplicationJob
  queue_as :default

  STEPS = %w[metadata structure roles members emojis stickers bans invites joining].freeze

  def perform(nostr_group_id, user_id)
    @gid = nostr_group_id
    @user = User.find_by(id: user_id)
    return unless @user

    cache_key = "nostr_sync:#{@gid}:#{@user.id}"

    begin
      service = NostrServerSyncService.new(@gid, joining_user: @user)

      # Sync each step with progress updates
      sync_step(cache_key, "metadata", 10) { service.send(:sync_metadata) }
      sync_step(cache_key, "structure", 25) { service.send(:sync_structure) }
      sync_step(cache_key, "roles", 35) { service.send(:sync_roles) }
      sync_step(cache_key, "members", 50) { service.send(:sync_members) }
      sync_step(cache_key, "emojis", 60) { service.send(:sync_emojis) }
      sync_step(cache_key, "stickers", 70) { service.send(:sync_stickers) }
      sync_step(cache_key, "bans", 80) { service.send(:sync_bans) }
      sync_step(cache_key, "invites", 85) { service.send(:sync_invites) }
      sync_step(cache_key, "pins", 90) { service.send(:sync_pins) }

      # Create membership
      update_progress(cache_key, "joining", 95)
      server = Server.find_by(nostr_group_id: @gid)
      unless server
        update_progress(cache_key, "failed", 0, error: "Server not found after sync")
        return
      end

      unless @user.servers.include?(server)
        server.server_memberships.create!(user: @user)

        if @user.nostr_public_key.present?
          NostrServerPublishJob.perform_later(@user.id, server.id, "member", pubkey: @user.nostr_public_key)
        end
      end

      update_progress(cache_key, "complete", 100)
      Rails.logger.info("[NostrServerJoinJob] Join complete for #{@gid} by user #{@user.id}")
    rescue => e
      Rails.logger.error("[NostrServerJoinJob] Failed: #{e.message}")
      update_progress(cache_key, "failed", 0, error: e.message)
    end
  end

  private

  def sync_step(cache_key, step, progress)
    update_progress(cache_key, step, progress)
    yield
  rescue => e
    Rails.logger.warn("[NostrServerJoinJob] Step #{step} failed: #{e.message}")
    # Continue to next step — partial sync is better than no sync
  end

  def update_progress(cache_key, step, progress, error: nil)
    data = { step: step, progress: progress }
    data[:error] = error if error
    Rails.cache.write(cache_key, data, expires_in: 5.minutes)
  end
end
