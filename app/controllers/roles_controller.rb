class RolesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_current_membership
  before_action :ensure_manage_roles!
  before_action :set_role, only: [ :update, :destroy, :members, :toggle_member ]

  def create
    max_position = @server.roles.where("json_extract(permissions, '$.owner') IS NOT TRUE").maximum(:position) || 0
    role = @server.roles.new(
      name: "New Role",
      color: "#99aab5",
      position: max_position + 1,
      permissions: Role::DEFAULT_PERMISSIONS
    )

    if role.save
      publish_server_roles
      render json: role_json(role), status: :created
    else
      render json: { errors: role.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @role.owner?
      return render json: { error: "Cannot edit the Owner role" }, status: :forbidden
    end

    attrs = {}
    attrs[:name] = params[:name] if params[:name].present? && !@role.everyone?
    attrs[:color] = params[:color] if params[:color].present?
    attrs[:hoist] = params[:hoist] if params.key?(:hoist)
    attrs[:permissions] = params[:permissions].to_unsafe_h if params[:permissions].present?

    if @role.update(attrs)
      broadcast_roles_updated
      publish_server_roles
      render json: role_json(@role)
    else
      render json: { errors: @role.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    if @role.undeletable?
      return render json: { error: "This role cannot be deleted" }, status: :forbidden
    end

    @role.membership_roles.destroy_all
    @role.destroy

    broadcast_roles_updated
    publish_server_roles
    render json: { success: true }
  end

  def members
    memberships = @server.server_memberships.includes(:user, :roles)

    if params[:q].present?
      q = "%#{params[:q].downcase}%"
      memberships = memberships.joins(:user).where(
        "LOWER(users.username) LIKE :q OR LOWER(users.display_name) LIKE :q OR LOWER(server_memberships.nickname) LIKE :q",
        q: q
      )
    end

    members_json = memberships.limit(100).map do |ms|
      user = ms.user
      {
        user_id: user.public_id,
        username: user.username,
        display_name: user.display_name_for(@server),
        avatar_url: user.effective_avatar_url,
        profile_color: user.profile_color || "#1e1c1b",
        has_role: ms.roles.any? { |r| r.id == @role.id }
      }
    end

    render json: members_json
  end

  def toggle_member
    if @role.owner? || @role.everyone?
      return render json: { error: "Cannot modify members for this role" }, status: :forbidden
    end

    user = User.find_by!(public_id: params[:user_id])
    membership = @server.server_memberships.find_by!(user: user)
    existing = MembershipRole.find_by(server_membership: membership, role: @role)

    if existing
      existing.destroy!
      action = "removed"
    else
      MembershipRole.create!(server_membership: membership, role: @role)
      action = "added"
    end

    broadcast_roles_updated
    publish_server_roles
    if user.nostr_public_key.present? && current_user.nostr_public_key.present?
      NostrServerPublishJob.perform_later(current_user.id, @server.id, "member", pubkey: user.nostr_public_key)
    end

    render json: { action: action, member_count: @role.membership_roles.count }
  end

  def reorder
    roles_data = params[:roles] || []

    ActiveRecord::Base.transaction do
      roles_data.each do |role_data|
        role = @server.roles.find_by(public_id: role_data[:id])
        next unless role
        next if role.owner?
        role.update_column(:position, role_data[:position].to_i)
      end
    end

    broadcast_roles_updated
    publish_server_roles

    render json: { success: true }
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def set_current_membership
    @current_membership = @server.server_memberships.find_by(user: current_user)
  end

  def ensure_manage_roles!
    unless @current_membership&.has_permission?("manage_roles") || @current_membership&.admin?
      render json: { error: "Permission denied" }, status: :forbidden
    end
  end

  def set_role
    @role = @server.roles.find_by!(public_id: params[:id])
  end

  def role_json(role)
    {
      id: role.public_id,
      name: role.name,
      color: role.color,
      position: role.position,
      permissions: role.permissions,
      hoist: role.hoist,
      member_count: role.membership_roles.count,
      is_owner: role.owner?,
      is_everyone: role.everyone?,
      is_voice_provider: role.voice_provider?,
      undeletable: role.undeletable?
    }
  end

  def broadcast_roles_updated
    # Build a user_id => color map so clients can update message name colors
    color_map = {}
    @server.server_memberships.includes(:roles, :user).find_each do |ms|
      color_map[ms.user.public_id] = ms.display_color
    end
    ServerChannel.broadcast_to(@server, { type: "roles_updated", color_map: color_map })
  end

  def publish_server_roles
    return unless current_user.nostr_public_key.present?
    NostrServerPublishJob.perform_later(current_user.id, @server.id, "roles")
  end
end
