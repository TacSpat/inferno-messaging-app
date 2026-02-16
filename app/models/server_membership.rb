class ServerMembership < ApplicationRecord
  include HasPublicId
  include InstanceLimits
  belongs_to :user
  has_paper_trail
  belongs_to :server
  belongs_to :server_folder, optional: true
  has_many :membership_roles, dependent: :destroy
  has_many :roles, through: :membership_roles

  scope :ordered, -> { order(position: :asc, joined_at: :asc) }

  validates :user_id, uniqueness: { scope: :server_id }
  validate :within_member_limit, on: :create

  before_create :set_joined_at
  after_create :send_welcome_message
  after_create_commit :broadcast_member_join
  after_destroy_commit :broadcast_member_leave

  def has_permission?(permission)
    return true if server.owner == user
    everyone_role = server.roles.find_by(name: "@everyone")
    return true if everyone_role&.has_permission?(permission)
    roles.any? { |r| r.has_permission?(permission) }
  end

  def owner?
    server.owner == user
  end

  def admin?
    owner? || roles.any?(&:admin?)
  end

  def top_role
    roles.ordered.first
  end

  def top_hoisted_role
    roles.select { |r| r.hoist? && r.name != "New Role" && !r.owner? }.max_by(&:position)
  end

  private

  def set_joined_at
    self.joined_at ||= Time.current
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

  def within_member_limit
    if server && instance_config.member_limit_reached_for?(server)
      errors.add(:base, "This server has reached its member limit (#{instance_config.max_members_per_server})")
    end
  end
end
