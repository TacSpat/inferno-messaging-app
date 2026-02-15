class InvitesController < ApplicationController
  before_action :set_invite

  def show
    @server = @invite.server
    @member_count = @server.members.count
    @online_count = @server.members.where(online_state: :online).count
    @already_member = user_signed_in? && current_user.servers.include?(@server)
  end

  def accept
    @server = @invite.server

    # Not logged in — store invite and redirect to registration
    unless user_signed_in?
      session[:pending_invite_code] = @invite.code
      redirect_to new_user_registration_path, notice: "Create an account to join #{@server.name}!"
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
      redirect_to root_path, alert: "Invalid, expired, or reached maximum uses invite link."
    end
  end
end
