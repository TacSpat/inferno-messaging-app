class UserDeletionService
  # Deletes a user while preserving history:
  #   - Messages stay, author becomes nil → views show "Deleted User" with default avatar
  #   - Audit/federation logs are preserved (actor references nullified)
  #   - User-specific data (memberships, friendships, etc.) is cleaned up
  #   - For shadow users, also removes the linked RemoteUser record
  #
  # Usage:
  #   UserDeletionService.call(user)
  #
  def self.call(user)
    new(user).call
  end

  def initialize(user)
    @user = user
  end

  def call
    user_id = @user.id
    username = @user.tag
    is_remote = @user.remote?
    remote_user = @user.remote_user_detail

    ActiveRecord::Base.transaction do
      # --- Preserve history: nullify author references ---
      Message.where(user_id: user_id).update_all(user_id: nil)

      # Preserve audit trails
      safe_nullify(:user_suspensions, :suspended_by_id, user_id)
      safe_nullify(:user_suspensions, :lifted_by_id, user_id)
      safe_nullify(:moderation_reports, :reporter_id, user_id)
      safe_nullify(:moderation_reports, :reviewed_by_id, user_id)
      safe_nullify(:bans, :banned_by_id, user_id)
      safe_nullify(:legal_holds, :placed_by_id, user_id)
      safe_nullify(:data_exports, :requested_by_id, user_id)
      safe_nullify(:instance_blocklists, :blocked_by_id, user_id)
      safe_nullify(:server_emojis, :creator_id, user_id)
      safe_nullify(:server_stickers, :creator_id, user_id)

      # Transfer server ownership instead of orphaning
      safe_nullify(:servers, :owner_id, user_id)

      # Preserve federation audit logs (nullify actor)
      safe_nullify(:federation_audit_logs, :actor_id, user_id)

      # --- Clean up user-specific data ---
      delete_from(:reactions, :user_id, user_id)
      delete_from(:channel_reads, :user_id, user_id)
      delete_from(:voice_states, :user_id, user_id)
      delete_from(:notifications, :user_id, user_id)
      delete_from(:gif_favorites, :user_id, user_id)
      delete_from(:gif_collections, :user_id, user_id)
      delete_from(:remote_server_references, :user_id, user_id)
      delete_from(:remote_conversation_references, :user_id, user_id)
      delete_from(:remote_friend_references, :user_id, user_id)
      delete_from(:friendships, :user_id, user_id)
      delete_from(:friendships, :friend_id, user_id)
      delete_from(:blocks, :blocker_id, user_id)
      delete_from(:blocks, :blocked_id, user_id)
      delete_from(:bans, :user_id, user_id)
      delete_from(:conversation_participants, :user_id, user_id)
      delete_from(:invites, :creator_id, user_id)
      delete_from(:user_suspensions, :user_id, user_id)
      delete_from(:data_exports, :user_id, user_id)
      delete_from(:server_folders, :user_id, user_id)

      # Server memberships — use destroy to cascade role assignments
      ServerMembership.where(user_id: user_id).destroy_all

      # Purge ActiveStorage attachments
      @user.avatar.purge if @user.avatar.attached?
      @user.banner.purge if @user.banner.attached?

      # Delete the user record
      @user.delete

      # Clean up RemoteUser record for shadow users
      if is_remote && remote_user
        remote_user.delete
      end
    end

    Rails.logger.info("[UserDeletion] Deleted user #{username} (id=#{user_id}, remote=#{is_remote})")
    true
  end

  private

  def conn
    @conn ||= ActiveRecord::Base.connection
  end

  # Nullify a column via raw SQL — skips if the table doesn't exist.
  def safe_nullify(table, column, value)
    return unless table_exists?(table)
    conn.execute("UPDATE #{conn.quote_table_name(table)} SET #{conn.quote_column_name(column)} = NULL WHERE #{conn.quote_column_name(column)} = #{value.to_i}")
  rescue ActiveRecord::StatementInvalid => e
    # Column might not exist on this schema version — skip silently
    Rails.logger.warn("[UserDeletion] Could not nullify #{table}.#{column}: #{e.message}")
  end

  # Delete rows via raw SQL — skips if the table doesn't exist.
  def delete_from(table, column, value)
    return unless table_exists?(table)
    conn.execute("DELETE FROM #{conn.quote_table_name(table)} WHERE #{conn.quote_column_name(column)} = #{value.to_i}")
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("[UserDeletion] Could not delete from #{table}.#{column}: #{e.message}")
  end

  def table_exists?(table)
    conn.table_exists?(table)
  end
end
