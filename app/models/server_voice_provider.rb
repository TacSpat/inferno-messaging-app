class ServerVoiceProvider < ApplicationRecord
  belongs_to :server
  belongs_to :user

  validates :user_id, uniqueness: { scope: :server_id, message: "is already a voice provider for this server" }
  validate :user_has_livekit_configured, on: :create

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(position: :asc, created_at: :asc) }

  after_create :assign_voice_provider_role
  after_destroy :remove_voice_provider_role

  private

  def user_has_livekit_configured
    unless user&.livekit_configured?
      errors.add(:base, "User must have LiveKit credentials configured before volunteering as a provider")
    end
  end

  def assign_voice_provider_role
    role = server.roles.find_by(name: "Voice Provider")
    role ||= server.roles.create!(
      name: "Voice Provider",
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
    role = server.roles.find_by(name: "Voice Provider")
    return unless role

    membership = user.server_memberships.find_by(server: server)
    membership&.roles&.delete(role)

    # Delete the role entirely if no providers left
    role.destroy if server.server_voice_providers.none?
  end
end
