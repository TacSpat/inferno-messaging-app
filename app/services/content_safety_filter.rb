# Orchestrates all content safety checks for incoming messages.
# Called after message creation to decide if a message should be auto-hidden.
#
# Filters (checked in order, first match wins):
#   0. CSAM hash — perceptual match against known CSAM hashes (non-negotiable, always on)
#   1. NSFW detection — local ONNX classifier flags explicit images
#   2. Unknown sender — not a friend or known contact
#   3. Report threshold — sender has N+ local reports
#   4. Reputation score — weighted multi-signal score below threshold
#   5. Image hash — perceptual match against previously-flagged content
#
# All auto-hides are reversible via the safety settings page (except CSAM).
#
class ContentSafetyFilter
  attr_reader :message, :config, :reason

  def initialize(message)
    @message = message
    @config = LocalConfig.current
    @reason = nil
  end

  # Run all enabled filters. Returns true if the message was auto-hidden.
  def check!
    return false if message.hidden?

    # CSAM check is non-negotiable — runs even on own messages
    if image_csam_match?
      auto_hide!("csam_match")
      return true
    end

    return false if message.user_id.present? && message.user == local_user # never filter own messages

    if nsfw_image_match?
      auto_hide!("nsfw")
    elsif unknown_sender?
      auto_hide!("unknown_sender")
    elsif over_report_threshold?
      auto_hide!("reported")
    elsif below_reputation_threshold?
      auto_hide!("low_reputation")
    elsif image_hash_match?
      auto_hide!("image_match")
    else
      # No filter triggered — but if image hashing is enabled,
      # proactively hash this message's images for future matching
      store_image_hashes_async if config.safety_image_hash_enabled
      false
    end
  end

  private

  def local_user
    @local_user ||= User.first
  end

  def sender_pubkey
    @sender_pubkey ||= message.nostr_author_pubkey
  end

  # --- Filter 0: CSAM hash matching (non-negotiable, always on) ---

  def image_csam_match?
    return false unless message.files.attached?

    hashes = ImageHasher.hash_message_attachments(message)
    hashes.any? { |h| CsamHashEntry.fuzzy_match?(h[:hash_value], hash_type: h[:hash_type]) }
  end

  # --- Filter 1: NSFW image detection (ONNX model) ---

  def nsfw_image_match?
    return false unless NsfwDetector.available?
    return false unless message.files.attached?
    # Skip NSFW detection in age-restricted server channels (explicit content expected)
    return false if message.channel&.server&.age_restricted?

    NsfwDetector.any_explicit?(message)
  end

  # --- Filter 2: Unknown sender ---

  def unknown_sender?
    return false unless config.safety_hide_unknown_senders
    return false if sender_pubkey.blank?

    contact = Contact.find_by(pubkey: sender_pubkey)
    # Unknown = no contact record, or contact exists but not a friend
    contact.nil? || !contact.accepted?
  end

  # --- Filter 3: Report threshold ---

  def over_report_threshold?
    threshold = config.safety_report_threshold
    return false if threshold.zero?
    return false if sender_pubkey.blank?

    report_count = Contact.where(pubkey: sender_pubkey).pick(:report_count) || 0
    remote_count = RemoteMember.where(pubkey: sender_pubkey).maximum(:report_count) || 0
    [ report_count, remote_count ].max >= threshold
  end

  # --- Filter 4: Reputation score ---

  def below_reputation_threshold?
    return false unless config.safety_reputation_enabled
    return false if sender_pubkey.blank?

    scorer = ReputationScorer.new(sender_pubkey, sensitivity: config.safety_reputation_sensitivity)
    scorer.score < config.safety_reputation_threshold
  end

  # --- Filter 5: Image hash matching ---

  def image_hash_match?
    return false unless config.safety_image_hash_enabled
    return false unless message.files.attached?

    hashes = ImageHasher.hash_message_attachments(message)
    hashes.any? { |h| ContentHash.match?(h[:hash_value], hash_type: h[:hash_type]) }
  end

  # --- Auto-hide ---

  def auto_hide!(filter_reason)
    @reason = filter_reason
    message.transaction do
      # Store image hashes before purging attachments
      store_image_hashes if config.safety_image_hash_enabled && message.files.attached?

      message.files.each do |att|
        message.hidden_attachment_records.create!(
          original_filename: att.filename.to_s,
          content_type: att.content_type,
          byte_size: att.byte_size,
          checksum: att.checksum,
          purged_at: Time.current,
          purged_by: local_user
        )
      end
      message.files.purge
      message.update!(
        hidden_at: Time.current,
        hidden_by: local_user,
        hidden_reason: "auto:#{filter_reason}"
      )
      message.send(:increment_author_report_count!) if filter_reason != "unknown_sender"
    end

    Rails.logger.info("[ContentSafetyFilter] Auto-hidden message #{message.id} (#{filter_reason})")
    true
  rescue => e
    Rails.logger.error("[ContentSafetyFilter] Failed to auto-hide message #{message.id}: #{e.message}")
    false
  end

  # --- Image hash storage ---

  def store_image_hashes
    ImageHasher.hash_message_attachments(message).each do |h|
      ContentHash.find_or_create_by!(
        hash_value: h[:hash_value],
        hash_type: h[:hash_type]
      ) do |ch|
        ch.media_type = h[:media_type]
        ch.original_filename = h[:original_filename]
        ch.message = message
      end
    end
  end

  def store_image_hashes_async
    # Only hash in background to avoid slowing down message delivery
    StoreImageHashesJob.perform_later(message.id) if defined?(StoreImageHashesJob)
  end
end
