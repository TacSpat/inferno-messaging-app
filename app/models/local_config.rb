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
end
