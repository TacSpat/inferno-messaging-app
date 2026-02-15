class ServerPolicy < ApplicationPolicy
  def edit?
    member_has_permission?("manage_server")
  end

  def update?
    member_has_permission?("manage_server")
  end

  def destroy?
    record.owner == user
  end

  def manage_channels?
    member_has_permission?("manage_channels")
  end

  def manage_roles?
    member_has_permission?("manage_roles")
  end

  def kick_members?
    member_has_permission?("kick_members")
  end

  def ban_members?
    member_has_permission?("ban_members")
  end

  private

  def membership
    @membership ||= record.server_memberships.find_by(user: user)
  end

  def member_has_permission?(permission)
    return false unless membership
    return true if record.owner == user # Owner always has everything
    membership.has_permission?(permission)
  end
end
