# Orchestrates all content safety checks for incoming messages.
# Called after message creation to decide if a message should be auto-hidden.
#
# Filters (checked in order, first match wins):
#   1. Keyword filter — text matching against user-defined word list
#   2. Unknown sender — not a friend or known contact
#   3. Report threshold — sender has N+ local reports
#   4. Reputation score — weighted multi-signal score below threshold
#   5. Image hash — perceptual match against previously-flagged content
#
# All auto-hides are reversible via the safety settings page.
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
    return false if message.user_id.present? && message.user == local_user # never filter own messages

    if keyword_match?
      auto_hide!("keyword")
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

  # --- Filter 1: Keyword matching (presets + user rules) ---

  def keyword_match?
    return false if message.content.blank?

    content = message.content

    # Preset checks (independent toggles, checked first)
    return true if config.safety_block_links && has_unsafe_links?(content)
    return true if config.safety_block_phone_numbers && has_phone_numbers?(content)
    return true if config.safety_block_all_caps && all_caps?(content)
    return true if config.safety_block_spam_chars && spam_chars?(content)

    # User-defined keyword rules
    keywords = config.safety_keyword_filter.to_s.strip
    return false if keywords.blank?

    content_lower = content.downcase
    keywords.split("\n").any? do |line|
      word = line.strip.downcase
      next false if word.blank?

      if word.end_with?("*") && !word.start_with?("*")
        # "hate*" -> matches words starting with "hate"
        prefix = Regexp.escape(word.chomp("*"))
        content.match?(Regexp.new("\\b#{prefix}\\w*", Regexp::IGNORECASE))
      elsif word.start_with?("*") && !word.end_with?("*")
        # "*phobic" -> matches words ending with "phobic"
        suffix = Regexp.escape(word.delete_prefix("*"))
        content.match?(Regexp.new("\\w*#{suffix}\\b", Regexp::IGNORECASE))
      else
        # Plain word/phrase — case-insensitive include
        content_lower.include?(word)
      end
    end
  end

  # Block messages with external links (excluding known safe embeds)
  def has_unsafe_links?(content)
    urls = content.scan(Message::URL_REGEX)
    return false if urls.empty?

    safe_patterns = [
      Message::IMAGE_URL_REGEX,
      Message::VIDEO_URL_REGEX,
      Message::TENOR_REGEX,
      Message::YOUTUBE_REGEX,
      Message::INSTAGRAM_REGEX,
      Message::TIKTOK_REGEX,
      Message::INFERNO_INVITE_REGEX,
      Message::NOSTR_INVITE_REGEX,
      Message::NOSTR_SERVER_REGEX,
      Message::DISCORD_LINK_REGEX,
      Message::MESSAGE_LINK_REGEX,
      Message::REDDIT_REGEX,
      /\/rails\/active_storage\//i,
      /(?:#{Message::BLOSSOM_DOMAINS.map { |d| Regexp.escape(d) }.join("|")})\/[0-9a-f]{64}/i
    ]

    urls.any? do |url|
      !safe_patterns.any? { |pattern| url.match?(pattern) }
    end
  end

  # Block messages with phone numbers
  def has_phone_numbers?(content)
    content.match?(/(?:\+?\d{1,3}[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}/)
  end

  # Block ALL CAPS messages (>80% uppercase, min 20 chars)
  def all_caps?(content)
    return false if content.length < 20
    letters = content.gsub(/[^a-zA-Z]/, "")
    return false if letters.empty?
    upper_ratio = letters.gsub(/[^A-Z]/, "").length.to_f / letters.length
    upper_ratio > 0.8
  end

  # Block messages with 10+ repeated characters
  def spam_chars?(content)
    content.match?(/(.)\1{9,}/)
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
    [report_count, remote_count].max >= threshold
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
