class RolesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_current_membership
  before_action :ensure_manage_roles!
  before_action :set_role, only: [ :update, :destroy ]

  def create
    max_position = @server.roles.where.not("permissions @> ?", { owner: true }.to_json).maximum(:position) || 0
    role = @server.roles.new(
      name: "New Role",
      color: "#99aab5",
      position: max_position + 1,
      permissions: Role::DEFAULT_PERMISSIONS
    )

    if role.save
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
    attrs[:color] = params[:color] if params[:color].present? && !@role.everyone?
    attrs[:hoist] = params[:hoist] if params.key?(:hoist)
    attrs[:permissions] = params[:permissions].to_unsafe_h if params[:permissions].present?

    if @role.update(attrs)
      ServerChannel.broadcast_to(@server, { type: "roles_updated" })
      render json: role_json(@role)
    else
      render json: { errors: @role.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    if @role.system_role?
      return render json: { error: "Cannot delete system roles" }, status: :forbidden
    end

    @role.membership_roles.destroy_all
    @role.destroy

    ServerChannel.broadcast_to(@server, { type: "roles_updated" })
    render json: { success: true }
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

    # Broadcast so all clients refresh their member lists
    ServerChannel.broadcast_to(@server, { type: "roles_updated" })

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
      is_everyone: role.everyone?
    }
  end
end
