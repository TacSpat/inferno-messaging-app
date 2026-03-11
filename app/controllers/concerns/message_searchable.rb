module MessageSearchable
  extend ActiveSupport::Concern

  private

  def apply_search_filters(messages)
    if params[:q].present?
      messages = messages.where("content LIKE ?", "%#{ActiveRecord::Base.sanitize_sql_like(params[:q])}%")
    end

    # from: supports multiple users (OR)
    from_values = Array(params[:from])
    if from_values.any?(&:present?)
      user_ids = []
      pubkeys = []
      from_values.each do |val|
        next if val.blank?
        user = User.find_by(public_id: val) || User.find_by(username: val)
        if user
          user_ids << user.id
        else
          pubkeys << val
        end
      end
      conditions = []
      conditions << messages.where(user_id: user_ids) if user_ids.any?
      conditions << messages.where(nostr_author_pubkey: pubkeys) if pubkeys.any?
      if conditions.any?
        messages = conditions.length == 1 ? conditions.first : conditions.first.or(conditions.last)
      end
    end

    if params[:before].present?
      messages = messages.where("created_at < ?", Time.zone.parse(params[:before]))
    end
    if params[:after].present?
      messages = messages.where("created_at > ?", Time.zone.parse(params[:after]))
    end
    if params[:on].present?
      date = Date.parse(params[:on])
      messages = messages.where(created_at: date.beginning_of_day..date.end_of_day)
    end

    # in: supports multiple channels (OR)
    in_values = Array(params[:in])
    if in_values.any?(&:present?)
      channels = in_values.filter_map do |val|
        Channel.find_by(public_id: val) || Channel.find_by(name: val)
      end
      messages = messages.where(channel: channels) if channels.any?
    end

    # has: supports multiple types (OR via union)
    has_values = Array(params[:has])
    if has_values.any?(&:present?)
      has_conditions = []
      has_values.each do |val|
        case val
        when "file", "attachment"
          has_conditions << ActiveStorage::Attachment.where(record_type: "Message", name: "files").select(:record_id)
        when "image"
          blob_ids = ActiveStorage::Blob.where("content_type LIKE ?", "image/%").select(:id)
          has_conditions << ActiveStorage::Attachment.where(record_type: "Message", name: "files", blob_id: blob_ids).select(:record_id)
        when "link"
          # Handled separately as content filter
          messages = messages.where("content LIKE ?", "%http%")
        end
      end
      if has_conditions.any?
        all_ids = has_conditions.flat_map { |q| q.pluck(:record_id) }.uniq
        messages = messages.where(id: all_ids)
      end
    end

    if params[:pinned] == "true"
      messages = messages.where(pinned: true)
    end
    messages
  end

  def search_target_time
    if params[:after].present?
      Time.zone.parse(params[:after])
    elsif params[:on].present?
      Date.parse(params[:on]).beginning_of_day
    elsif params[:before].present?
      Time.zone.parse(params[:before]) - 1.year
    end
  end

  def backfill_channel_history!(channel)
    target = search_target_time
    return unless target
    return unless channel.nostr_group_id.present?
    # Skip backfill for encrypted channels where user lost access — we can't decrypt new events
    return if channel.encrypted? && channel.visible_to?(current_user) != :full

    earliest_local = channel.messages.minimum(:created_at)
    return if earliest_local && earliest_local <= target

    until_time = earliest_local&.to_i || Time.current.to_i
    filter = {
      kinds: [ 9 ],
      "#h" => [ channel.nostr_group_id ],
      since: target.to_i,
      until: until_time
    }

    events = RelayService.fetch_from_all(filter, timeout: 10)
    NostrHistoryFetcher.send(:import_channel_events, channel, events) if events.any?
  rescue => e
    Rails.logger.warn("[MessageSearch] Channel backfill error: #{e.message}")
  end

  def backfill_dm_history!(conversation)
    target = search_target_time
    return unless target

    owner = User.owner
    return unless owner&.nostr_private_key.present?
    return unless conversation.counterparty_pubkey.present?

    earliest_local = conversation.messages.minimum(:created_at)
    return if earliest_local && earliest_local <= target

    until_time = earliest_local&.to_i || Time.current.to_i
    filter = {
      kinds: [ 14, 1059, 4 ],
      "#p" => [ owner.nostr_public_key ],
      authors: [ conversation.counterparty_pubkey ],
      since: target.to_i,
      until: until_time
    }

    events = RelayService.fetch_from_all(filter, timeout: 10)
    NostrHistoryFetcher.send(:import_dm_events, conversation, owner, events) if events.any?
  rescue => e
    Rails.logger.warn("[MessageSearch] DM backfill error: #{e.message}")
  end
end
