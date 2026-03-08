class Role < ApplicationRecord
  include HasPublicId
  include InstanceLimits
  belongs_to :server
  has_many :membership_roles, dependent: :destroy
  has_many :server_memberships, through: :membership_roles

  DEFAULT_PERMISSIONS = {
    send_messages: true,
    read_messages: true,
    read_message_history: true,
    attach_files: true,
    send_gifs: true,
    send_custom_emojis: true,
    send_custom_stickers: true,
    add_reactions: true,
    change_nickname: true,
    create_invite: true,
    create_emojis: false,
    create_stickers: false,
    mention_everyone: false,
    manage_messages: false,
    manage_channels: false,
    manage_roles: false,
    manage_invites: false,
    manage_emojis: false,
    manage_server: false,
    kick_members: false,
    ban_members: false,
    administrator: false,
    connect_voice: true,
    speak: true,
    video: true,
    screen_share: true,
    mute_members: false,
    deafen_members: false,
    move_members: false
  }.freeze

  ADMIN_PERMISSIONS = DEFAULT_PERMISSIONS.merge(
    mention_everyone: true,
    create_emojis: true,
    create_stickers: true,
    manage_messages: true,
    manage_channels: true,
    manage_invites: true,
    manage_emojis: true,
    manage_roles: true,
    kick_members: true,
    ban_members: true,
    administrator: true,
    mute_members: true,
    deafen_members: true,
    move_members: true
  ).freeze

  OWNER_PERMISSIONS = ADMIN_PERMISSIONS.merge(
    manage_server: true,
    owner: true  # Can never be revoked, only transferred
  ).freeze

  validates :name, presence: true, length: { maximum: 50 }
  validates :position, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :within_role_limit, on: :create
  validate :no_rename_system_roles, on: :update

  scope :ordered, -> { order(position: :desc) }

  def has_permission?(permission)
    # Owner has everything
    return true if permissions&.dig("owner") == true
    # Admin has almost everything (except owner-only stuff like manage_server)
    return true if permissions&.dig("administrator") == true && permission.to_s != "owner"
    permissions&.dig(permission.to_s) == true
  end

  def owner?
    permissions&.dig("owner") == true
  end

  def admin?
    permissions&.dig("administrator") == true
  end

  def everyone?
    name == "@everyone"
  end

  def voice_provider?
    role_type == "voice_provider"
  end

  def system_role?
    owner? || everyone?
  end

  def undeletable?
    system_role? || voice_provider?
  end

  private

  def within_role_limit
    if server && instance_config.role_limit_reached_for?(server)
      errors.add(:base, "This server has reached its role limit (#{instance_config.max_roles_per_server})")
    end
  end

  def no_rename_system_roles
    if name_changed? && (owner? || name_was == "@everyone")
      errors.add(:name, "cannot be changed for system roles")
    end
  end
end
