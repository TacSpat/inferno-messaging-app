class PruneMessagesJob < ApplicationJob
  queue_as :default

  def perform
    config = LocalConfig.current
    return unless config.pruning_enabled?

    case config.pruning_strategy
    when "time_based"
      prune_by_time(config)
    when "storage_based"
      prune_attachments_by_time(config)
      prune_by_time(config)
      prune_by_db_size(config)
    end
  end

  private

  def prune_by_time(config)
    return if config.message_retention_days.zero?

    cutoff = config.message_retention_days.days.ago
    scope = Message.where("created_at < ?", cutoff)
    scope = scope.where(hidden_at: nil) # never prune hidden/flagged messages (evidence)
    scope = scope.where(pinned: [ false, nil ]) if config.keep_pinned_messages
    scope = apply_scope_filter(scope, config)

    deleted = scope.delete_all
    Rails.logger.info "[PruneMessagesJob] Deleted #{deleted} messages older than #{cutoff}"
  end

  def prune_attachments_by_time(config)
    return if config.attachment_retention_days.zero?

    cutoff = config.attachment_retention_days.days.ago

    old_attachments = ActiveStorage::Attachment
      .where(record_type: "Message")
      .where(name: "files")
      .where("created_at < ?", cutoff)

    # Never prune attachments from hidden/flagged messages (evidence)
    hidden_message_ids = Message.where.not(hidden_at: nil).pluck(:id)
    old_attachments = old_attachments.where.not(record_id: hidden_message_ids) if hidden_message_ids.any?

    if config.keep_pinned_messages
      pinned_message_ids = Message.where(pinned: true).pluck(:id)
      old_attachments = old_attachments.where.not(record_id: pinned_message_ids) if pinned_message_ids.any?
    end

    # Apply scope filter via message IDs
    if config.prune_channel_messages && !config.prune_dm_messages
      channel_msg_ids = Message.where.not(channel_id: nil).pluck(:id)
      old_attachments = old_attachments.where(record_id: channel_msg_ids) if channel_msg_ids.any?
    elsif config.prune_dm_messages && !config.prune_channel_messages
      dm_msg_ids = Message.where.not(conversation_id: nil).pluck(:id)
      old_attachments = old_attachments.where(record_id: dm_msg_ids) if dm_msg_ids.any?
    elsif !config.prune_channel_messages && !config.prune_dm_messages
      return
    end

    count = old_attachments.count
    old_attachments.find_each do |attachment|
      attachment.purge_later
    end

    Rails.logger.info "[PruneMessagesJob] Queued #{count} attachments for purging older than #{cutoff}"
  end

  def prune_by_db_size(config)
    return if config.max_db_size_mb.zero?

    max_bytes = config.max_db_size_mb * 1024 * 1024
    db_path = ActiveRecord::Base.connection.execute("PRAGMA database_list").first["file"]
    return unless db_path.present? && File.exist?(db_path)

    total_deleted = 0
    # Delete in batches of 500 oldest messages until under limit
    loop do
      current_size = File.size(db_path)
      break if current_size <= max_bytes

      scope = Message.where(hidden_at: nil).order(:created_at)
      scope = scope.where(pinned: [ false, nil ]) if config.keep_pinned_messages
      scope = apply_scope_filter(scope, config)

      batch = scope.limit(500).pluck(:id)
      break if batch.empty?

      deleted = Message.where(id: batch).delete_all
      total_deleted += deleted

      # Reclaim space
      ActiveRecord::Base.connection.execute("PRAGMA incremental_vacuum") rescue nil
    end

    Rails.logger.info "[PruneMessagesJob] Deleted #{total_deleted} messages to reduce DB size under #{config.max_db_size_mb} MB" if total_deleted > 0
  end

  def apply_scope_filter(scope, config)
    if config.prune_channel_messages && !config.prune_dm_messages
      scope.where.not(channel_id: nil)
    elsif config.prune_dm_messages && !config.prune_channel_messages
      scope.where.not(conversation_id: nil)
    elsif !config.prune_channel_messages && !config.prune_dm_messages
      scope.none
    else
      scope
    end
  end
end
