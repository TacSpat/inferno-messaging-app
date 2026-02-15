class MessagePolicy < ApplicationPolicy
  def create?
    true
  end

  def edit?
    record.user == user
  end

  def update?
    record.user == user
  end

  def destroy?
    return true if record.user == user
    return false unless record.channel&.server

    membership = record.channel.server.server_memberships.find_by(user: user)
    membership&.has_permission?(:manage_messages) || membership&.admin? || false
  end
end
