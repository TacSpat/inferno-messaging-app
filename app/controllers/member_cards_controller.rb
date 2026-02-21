class MemberCardsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_member

  def profile_card
    render partial: "servers/profile_card", locals: { member: @member, server: @server }, layout: false
  end

  def context_menu
    render partial: "servers/member_context_menu", locals: { member: @member, server: @server }, layout: false
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def set_member
    @member = @server.members.includes(avatar_attachment: :blob, banner_attachment: :blob).find_by(public_id: params[:id])
    @member ||= @server.remote_members.find_by!(public_id: params[:id])
  end
end
