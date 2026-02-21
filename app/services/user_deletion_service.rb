class UserDeletionService
  # Deletes a user while preserving history:
  #   - Messages stay, author becomes nil - views show "Deleted User" with default avatar
  #   - User-specific data (memberships, contacts, etc.) is cleaned up
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

    ActiveRecord::Base.transaction do
      # --- Preserve history: nullify author references ---
      Message.where(user_id: user_id).update_all(user_id: nil)

      # Transfer server ownership instead of orphaning
      safe_nullify(:servers, :owner_id, user_id)
      safe_nullify(:server_emojis, :creator_id, user_id)
      safe_nullify(:server_stickers, :creator_id, user_id)

      # --- Clean up user-specific data ---
      delete_from(:reactions, :user_id, user_id)
      delete_from(:channel_reads, :user_id, user_id)
      delete_from(:notifications, :user_id, user_id)
      delete_from(:gif_favorites, :user_id, user_id)
      delete_from(:gif_collections, :user_id, user_id)
      delete_from(:blocks, :blocker_id, user_id)
      delete_from(:blocks, :blocked_id, user_id)
      delete_from(:bans, :user_id, user_id)
      delete_from(:conversation_participants, :user_id, user_id)
      delete_from(:invites, :creator_id, user_id)
      delete_from(:server_folders, :user_id, user_id)

      # Server memberships — use destroy to cascade role assignments
      ServerMembership.where(user_id: user_id).destroy_all

      # Clean up contacts
      Contact.delete_all

      # Purge ActiveStorage attachments
      @user.avatar.purge if @user.avatar.attached?
      @user.banner.purge if @user.banner.attached?

      # Delete the user record
      @user.delete
    end

    Rails.logger.info("[UserDeletion] Deleted user #{username} (id=#{user_id})")
    true
  end

  private

  def conn
    @conn ||= ActiveRecord::Base.connection
  end

  def safe_nullify(table, column, value)
    return unless table_exists?(table)
    conn.execute("UPDATE #{conn.quote_table_name(table)} SET #{conn.quote_column_name(column)} = NULL WHERE #{conn.quote_column_name(column)} = #{value.to_i}")
  rescue ActiveRecord::StatementInvalid => e
    Rails.logger.warn("[UserDeletion] Could not nullify #{table}.#{column}: #{e.message}")
  end

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
