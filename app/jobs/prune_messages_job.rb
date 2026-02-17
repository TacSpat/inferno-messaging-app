class PruneMessagesJob < ApplicationJob
  queue_as :default

  def perform
    config = InstanceConfig.current
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
    scope = exclude_held_messages(scope)

    deleted = scope.delete_all
    Rails.logger.info "[PruneMessagesJob] Deleted #{deleted} messages older than #{cutoff}"
  end

  def prune_attachments_by_time(config)
    return if config.attachment_retention_days.zero?

    cutoff = config.attachment_retention_days.days.ago

    # Find message attachments older than the retention period
    old_attachments = ActiveStorage::Attachment
      .where(record_type: "Message")
      .where(name: "files")
      .where("created_at < ?", cutoff)

    if config.keep_pinned_messages
      pinned_message_ids = Message.where(pinned: true).pluck(:id)
      old_attachments = old_attachments.where.not(record_id: pinned_message_ids) if pinned_message_ids.any?
    end

    # Exclude attachments on messages protected by legal holds
    protected_msg_ids = held_message_ids
    old_attachments = old_attachments.where.not(record_id: protected_msg_ids) if protected_msg_ids.any?

    count = old_attachments.count
    old_attachments.find_each do |attachment|
      attachment.purge_later
    end

    Rails.logger.info "[PruneMessagesJob] Queued #{count} attachments for purging older than #{cutoff}"
  end

  def exclude_held_messages(scope)
    ids = held_user_and_channel_ids
    scope = scope.where.not(user_id: ids[:user_ids]) if ids[:user_ids].any?
    scope = scope.where.not(channel_id: ids[:channel_ids]) if ids[:channel_ids].any?
    scope
  end

  def held_message_ids
    ids = held_user_and_channel_ids
    scope = Message.none
    scope = Message.where(user_id: ids[:user_ids]) if ids[:user_ids].any?
    scope = scope.or(Message.where(channel_id: ids[:channel_ids])) if ids[:channel_ids].any?
    scope.pluck(:id)
  end

  def held_user_and_channel_ids
    held_user_ids = LegalHold.active.where(holdable_type: "User").pluck(:holdable_id)
    held_server_ids = LegalHold.active.where(holdable_type: "Server").pluck(:holdable_id)
    held_channel_ids = LegalHold.active.where(holdable_type: "Channel").pluck(:holdable_id)
    held_channel_ids += Channel.where(server_id: held_server_ids).pluck(:id) if held_server_ids.any?
    { user_ids: held_user_ids, channel_ids: held_channel_ids }
  end
end
