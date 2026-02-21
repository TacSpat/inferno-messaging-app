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
    end
  end

  private

  def prune_by_time(config)
    return if config.message_retention_days.zero?

    cutoff = config.message_retention_days.days.ago
    scope = Message.where("created_at < ?", cutoff)
    scope = scope.where(pinned: [false, nil]) if config.keep_pinned_messages

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

    if config.keep_pinned_messages
      pinned_message_ids = Message.where(pinned: true).pluck(:id)
      old_attachments = old_attachments.where.not(record_id: pinned_message_ids) if pinned_message_ids.any?
    end

    count = old_attachments.count
    old_attachments.find_each do |attachment|
      attachment.purge_later
    end

    Rails.logger.info "[PruneMessagesJob] Queued #{count} attachments for purging older than #{cutoff}"
  end
end
