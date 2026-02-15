class ServerMembership < ApplicationRecord
  include HasPublicId
  belongs_to :user
  has_paper_trail
  belongs_to :server
  belongs_to :role, optional: true

  validates :user_id, uniqueness: { scope: :server_id }

  before_create :set_joined_at
  before_create :assign_default_role
  after_create :send_welcome_message
  after_create_commit :broadcast_member_join
  after_destroy_commit :broadcast_member_leave

  def has_permission?(permission)
    return true if server.owner == user
    role&.has_permission?(permission) || false
  end

  def owner?
    server.owner == user
  end

  def admin?
    owner? || role&.admin?
  end

  private

  def set_joined_at
    self.joined_at ||= Time.current
  end

  def assign_default_role
    self.role ||= server.roles.find_by(name: "@everyone")
  end

  def send_welcome_message
    return if server.owner == user
    server.send_welcome_message(user)
  end

  def broadcast_member_join
    ServerChannel.broadcast_to(server, {
      type: "member_join",
      html: ApplicationController.render(
        partial: "servers/member_item",
        locals: { member: user, server: server }
      ),
      user_id: user.public_id,
      member_count: server.members.count
    })
  end

  def broadcast_member_leave
    ServerChannel.broadcast_to(server, {
      type: "member_leave",
      user_id: user.public_id,
      member_count: server.members.count
    })
  end
end
