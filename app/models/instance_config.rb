class InstanceConfig < ApplicationRecord
  PRUNING_STRATEGIES = %w[none time_based storage_based].freeze
  FEDERATION_MODES = %w[open allowlist closed].freeze

  validates :pruning_strategy, inclusion: { in: PRUNING_STRATEGIES }
  validates :federation_mode, inclusion: { in: FEDERATION_MODES }
  validates :max_users, :max_servers, :max_servers_per_user,
            :max_channels_per_server, :max_categories_per_server,
            :max_members_per_server, :max_roles_per_server,
            :max_upload_size_mb, :max_storage_per_user_mb,
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

  # Check if a limit would be exceeded
  def user_limit_reached?
    !unlimited?(:max_users) && User.count >= max_users
  end

  def server_limit_reached?
    !unlimited?(:max_servers) && Server.count >= max_servers
  end

  def server_limit_reached_for?(user)
    user.owned_servers.count >= max_servers_per_user
  end

  def channel_limit_reached_for?(server)
    server.channels.count >= max_channels_per_server
  end

  def category_limit_reached_for?(server)
    server.categories.count >= max_categories_per_server
  end

  def member_limit_reached_for?(server)
    !unlimited?(:max_members_per_server) && server.members.count >= max_members_per_server
  end

  def role_limit_reached_for?(server)
    server.roles.count >= max_roles_per_server
  end

  def federation_open?
    federation_mode == "open"
  end

  def federation_closed?
    federation_mode == "closed"
  end

  def lockdown?
    lockdown_enabled?
  end

  # Granular lockdown checks
  def remote_auth_blocked?
    lockdown? || lockdown_remote_auth?
  end

  def remote_joins_blocked?
    lockdown? || lockdown_remote_joins?
  end

  def local_signups_blocked?
    lockdown? || lockdown_local_signups?
  end

  def invite_creation_blocked?
    lockdown? || lockdown_invite_creation?
  end

  # Emergency lockdown: enable all granular locks at once
  def emergency_lockdown!
    update!(
      lockdown_enabled: true,
      lockdown_remote_auth: true,
      lockdown_remote_joins: true,
      lockdown_local_signups: true,
      lockdown_invite_creation: true
    )
  end

  # Lift all lockdowns
  def lift_lockdown!
    update!(
      lockdown_enabled: false,
      lockdown_remote_auth: false,
      lockdown_remote_joins: false,
      lockdown_local_signups: false,
      lockdown_invite_creation: false
    )
  end
end
