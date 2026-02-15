class ServerMembersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :ensure_member!

  def index
    current_user.update_columns(online_state: User.online_states[:online], online_at: Time.current) if current_user.offline?
    @members = @server.members.includes(server_memberships: :roles, avatar_attachment: :blob)

    respond_to do |format|
      format.html do
        render partial: "servers/member_list_frame", locals: { members: @members, server: @server }, layout: false
      end
      format.json do
        render json: @members.map { |m| { id: m.public_id, username: m.username, display_name: m.display_name } }
      end
    end
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def ensure_member!
    unless current_user.servers.include?(@server)
      redirect_to root_path, alert: "You're not a member of this server."
    end
  end
end
