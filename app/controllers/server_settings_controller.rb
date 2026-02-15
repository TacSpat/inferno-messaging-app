class ServerSettingsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_current_membership
  before_action :ensure_permission!, except: [:invites, :create_invite, :destroy_invite]
  before_action :ensure_invite_permission!, only: [:invites, :create_invite, :destroy_invite]
  layout "server_settings"

  def overview
  end

  def update_overview
    if @server.update(server_params)
      redirect_to server_settings_overview_path(@server), notice: "Server updated."
    else
      render :overview, status: :unprocessable_entity
    end
  end

  def roles
    @roles = @server.roles.ordered
  end

  def members
    @memberships = @server.server_memberships.includes(user: { avatar_attachment: :blob }, role: {}).order(joined_at: :desc)
  end

  def update_member
    membership = @server.server_memberships.find_by!(public_id: params[:id])
    role = @server.roles.find_by!(public_id: params[:role_id])
    membership.update!(role: role)
    redirect_to server_settings_members_path(@server), notice: "#{membership.user.username} is now #{role.name}."
  end

  def kick_member
    membership = @server.server_memberships.find_by!(public_id: params[:id])
    return redirect_to server_settings_members_path(@server), alert: "Can't kick the owner." if membership.owner?
    username = membership.user.username
    membership.destroy
    redirect_to server_settings_members_path(@server), notice: "#{username} has been kicked."
  end

  def invites
    if @current_membership.has_permission?("manage_invites")
      @invites = @server.invites.active_invites.includes(:creator).order(created_at: :desc)
    else
      @invites = @server.invites.active_invites.where(creator: current_user).order(created_at: :desc)
    end
  end

  def create_invite
    expires_at = case params[:expires_in]
    when "30m" then 30.minutes.from_now
    when "1h"  then 1.hour.from_now
    when "6h"  then 6.hours.from_now
    when "12h" then 12.hours.from_now
    when "1d"  then 1.day.from_now
    when "7d"  then 7.days.from_now
    end

    max_uses = params[:max_uses].presence&.to_i

    invite = @server.invites.create!(creator: current_user, expires_at: expires_at, max_uses: max_uses)

    respond_to do |format|
      format.html { redirect_to server_settings_invites_path(@server), notice: "Invite created." }
      format.json { render json: { code: invite.code } }
    end
  end

  def destroy_invite
    invite = @server.invites.find(params[:invite_id])
    unless invite.creator == current_user || @current_membership.has_permission?("manage_invites")
      return redirect_to server_settings_invites_path(@server), alert: "You can only revoke your own invites."
    end
    invite.update!(active: false)
    redirect_to server_settings_invites_path(@server), notice: "Invite revoked."
  end

  def audit_log
    server_item_ids = {
      "Server" => [@server.id],
      "Channel" => @server.channel_ids,
      "Role" => @server.role_ids,
      "ServerMembership" => @server.server_membership_ids,
      "Ban" => @server.ban_ids,
      "Category" => @server.category_ids,
      "Invite" => @server.invite_ids
    }
    conditions = server_item_ids.map do |type, ids|
      PaperTrail::Version.where(item_type: type, item_id: ids)
    end
    @versions = conditions.reduce(:or).order(created_at: :desc).limit(50)
  end

  def bans
    @bans = @server.bans.includes(user: { avatar_attachment: :blob }, banned_by: { avatar_attachment: :blob }).order(created_at: :desc)
  end

  def create_ban
    user = User.find_by!(public_id: params[:user_id])
    ban = @server.bans.new(user: user, banned_by: current_user, reason: params[:reason])
    if ban.save
      redirect_to server_settings_bans_path(@server), notice: "#{user.username} has been banned."
    else
      redirect_to server_settings_members_path(@server), alert: ban.errors.full_messages.join(", ")
    end
  end

  def destroy_ban
    ban = @server.bans.find_by!(id: params[:ban_id])
    ban.destroy
    redirect_to server_settings_bans_path(@server), notice: "Ban removed."
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def set_current_membership
    @current_membership = @server.server_memberships.find_by(user: current_user)
  end

  def ensure_permission!
    unless @current_membership&.has_permission?("manage_server") || @current_membership&.admin?
      redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission."
    end
  end

  def ensure_invite_permission!
    unless @current_membership&.has_permission?("create_invite") || @current_membership&.has_permission?("manage_invites") || @current_membership&.admin?
      redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission."
    end
  end

  def server_params
    params.require(:server).permit(:name, :description, :icon, :welcome_message_enabled, :welcome_channel_id, :welcome_message_template)
  end
end
