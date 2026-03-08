class ServerVoiceProvider < ApplicationRecord
  belongs_to :server
  belongs_to :user, optional: true

  validates :user_id, uniqueness: { scope: :server_id, message: "is already a voice provider for this server" }, if: -> { user_id.present? }
  validates :provider_pubkey, presence: true, if: -> { user_id.blank? }
  validate :user_has_livekit_configured, on: :create, if: -> { user_id.present? }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(position: :asc, created_at: :asc) }

  after_create :assign_voice_provider_role, if: -> { user.present? }
  after_destroy :remove_voice_provider_role, if: -> { user.present? }

  def remote?
    user_id.blank? && provider_pubkey.present?
  end

  def local?
    !remote?
  end

  private

  def user_has_livekit_configured
    unless user&.livekit_configured?
      errors.add(:base, "User must have LiveKit credentials configured before volunteering as a provider")
    end
  end

  def assign_voice_provider_role
    role = server.roles.find_by(role_type: "voice_provider")
    role ||= server.roles.create!(
      name: "Voice Provider",
      role_type: "voice_provider",
      position: 1,
      color: "#2dd4bf",
      hoist: false,
      permissions: Role::DEFAULT_PERMISSIONS
    )

    membership = user.server_memberships.find_by(server: server)
    return unless membership
    membership.roles << role unless membership.roles.include?(role)
  end

  def remove_voice_provider_role
    role = server.roles.find_by(role_type: "voice_provider")
    return unless role

    membership = user.server_memberships.find_by(server: server)
    membership&.roles&.delete(role)
  end
end
