class LocalConfig < ApplicationRecord
  self.table_name = "instance_configs"

  PRUNING_STRATEGIES = %w[none time_based storage_based].freeze
  PROTECTION_LEVELS = %w[standard relaxed].freeze

  validates :pruning_strategy, inclusion: { in: PRUNING_STRATEGIES }
  validates :safety_protection_level, inclusion: { in: PROTECTION_LEVELS }, allow_nil: true
  validates :max_channels_per_server, :max_categories_per_server,
            :max_roles_per_server, :max_upload_size_mb,
            :message_retention_days, :attachment_retention_days,
            :max_cache_size_mb, :max_db_size_mb, :backfill_days,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Singleton access — there's only ever one row
  def self.current
    first_or_create!
  end

  def unlimited?(setting)
    send(setting).zero?
  end

  def pruning_enabled?
    pruning_strategy != "none"
  end

  def channel_limit_reached_for?(server)
    server.channels.count >= max_channels_per_server
  end

  def category_limit_reached_for?(server)
    server.categories.count >= max_categories_per_server
  end

  def role_limit_reached_for?(server)
    server.roles.count >= max_roles_per_server
  end

  def apply_protection_level!(level)
    case level
    when "standard"
      update!(
        safety_protection_level: "standard",
        safety_image_hash_enabled: true,
        safety_shared_hashes_enabled: true,
        safety_publish_hashes: true,
        safety_hide_unknown_senders: true,
        safety_block_links: true,
        safety_block_phone_numbers: true,
        safety_block_all_caps: true,
        safety_block_spam_chars: true,
        safety_reputation_enabled: true,
        safety_reputation_threshold: 30,
        safety_reputation_sensitivity: "moderate",
        safety_report_threshold: 3
      )
    when "relaxed"
      update!(
        safety_protection_level: "relaxed",
        safety_image_hash_enabled: true,
        safety_shared_hashes_enabled: true,
        safety_publish_hashes: true,
        safety_hide_unknown_senders: false,
        safety_block_links: false,
        safety_block_phone_numbers: false,
        safety_block_all_caps: false,
        safety_block_spam_chars: false,
        safety_reputation_enabled: false,
        safety_reputation_threshold: 30,
        safety_reputation_sensitivity: "moderate",
        safety_report_threshold: 0
      )
    end
  end

  # Auto-derive the instance relay URL from INSTANCE_DOMAIN when not explicitly set.
  def effective_instance_relay_url
    return instance_relay_url if instance_relay_url.present?
    domain = Rails.application.config.x.instance_domain
    if domain.present? && !domain.start_with?("localhost") && !domain.start_with?("127.")
      "wss://#{domain}/relay"
    else
      "ws://localhost:7777"
    end
  end
end
