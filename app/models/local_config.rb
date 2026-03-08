class LocalConfig < ApplicationRecord
  self.table_name = "instance_configs"

  PRUNING_STRATEGIES = %w[none time_based storage_based].freeze

  validates :pruning_strategy, inclusion: { in: PRUNING_STRATEGIES }
  validates :max_channels_per_server, :max_categories_per_server,
            :max_roles_per_server, :max_upload_size_mb,
            :message_retention_days, :attachment_retention_days,
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
