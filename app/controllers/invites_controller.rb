class InvitesController < ApplicationController
  before_action :set_invite

  def show
    @server = @invite.server
    @member_count = @server.members.count
    @online_count = @server.members.where(online_state: :online).count

    respond_to do |format|
      format.html do
        @already_member = user_signed_in? && current_user.servers.include?(@server)
      end
      format.json do
        render json: {
          server_name: @server.name,
          description: @server.description,
          icon_url: @server.icon.attached? ? rails_blob_url(@server.icon) : nil,
          member_count: @member_count,
          online_count: @online_count,
          invite_code: @invite.code
        }
      end
    end
  end

  def accept
    @server = @invite.server

    unless user_signed_in?
      session[:pending_invite_code] = @invite.code
      redirect_to new_user_session_path, notice: "Sign in to join #{@server.name}!"
      return
    end

    if current_user.servers.include?(@server)
      redirect_to server_channel_path(@server, @server.channels.ordered.first)
    else
      @invite.increment_uses!
      @server.server_memberships.create!(user: current_user)
      redirect_to server_channel_path(@server, @server.channels.ordered.first), notice: "Welcome to #{@server.name}!"
    end
  end

  private

  def set_invite
    @invite = Invite.find_by(code: params[:code])
    unless @invite&.usable?
      respond_to do |format|
        format.json { render json: { error: "Invalid, expired, or maxed-out invite." }, status: :not_found }
        format.html { redirect_to root_path, alert: "Invalid, expired, or reached maximum uses invite link." }
      end
    end
  end
end
