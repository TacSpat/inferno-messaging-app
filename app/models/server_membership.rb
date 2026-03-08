class ServerMembership < ApplicationRecord
  include HasPublicId
  belongs_to :user
  belongs_to :server
  belongs_to :server_folder, optional: true
  belongs_to :timed_out_by, class_name: "User", optional: true
  has_many :membership_roles, dependent: :destroy
  has_many :roles, through: :membership_roles

  scope :ordered, -> { order(position: :asc, joined_at: :asc) }

  validates :user_id, uniqueness: { scope: :server_id }
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

  def display_color
    # Walk roles top-down by position; skip Owner role and default gray
    sorted = roles.loaded? ? roles.sort_by { |r| -r.position } : roles.ordered.to_a
    sorted.each do |role|
      next if role.owner?
      return role.color if role.color.present? && role.color != "#99aab5"
    end
    "#ffffff"
  end

  def timed_out?
    timed_out_until.present? && timed_out_until > Time.current
  end

  def timeout_remaining
    return nil unless timed_out?
    timed_out_until - Time.current
  end

  def top_hoisted_role
    roles.select { |r| r.hoist? && !r.owner? && !r.everyone? }.max_by(&:position)
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
    return unless user
    ServerChannel.broadcast_to(server, {
      type: "member_leave",
      user_id: user.public_id,
      member_count: server.members.count
    })
  end
end
