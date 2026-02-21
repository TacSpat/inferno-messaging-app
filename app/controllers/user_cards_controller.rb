class UserCardsController < ApplicationController
  before_action :authenticate_user!

  def show
    @member = User.includes(avatar_attachment: :blob, banner_attachment: :blob)
                  .find_by!(public_id: params[:id])

    if params[:server_id].present?
      @server = Server.find_by(public_id: params[:server_id])
    end

    respond_to do |format|
      format.html do
        render partial: "users/card", locals: { member: @member, server: @server }, layout: false
      end
      format.json do
        membership = @server&.server_memberships&.find_by(user: @member)
        roles = membership&.roles&.where&.not(name: "@everyone")&.ordered&.map do |r|
          { name: r.name, color: r.color || "#ffffff" }
        end || []

        avatar_url = if @member.avatar.attached?
                       url_for(@member.avatar)
                     elsif @member.effective_avatar_url.present?
                       @member.effective_avatar_url
                     end

        banner_url = if @member.banner.attached?
                       url_for(@member.banner)
                     elsif @member.effective_banner_url.present?
                       @member.effective_banner_url
                     end

        render json: {
          public_id: @member.public_id,
          username: @member.username,
          display_name: @server ? @member.display_name_for(@server) : (@member.display_name.presence || @member.username),
          tag: @member.tag,
          bio: @member.bio,
          status: @member.status,
          status_emoji: @member.status_emoji,
          online_state: @member.online_state,
          profile_color: @member.profile_color || "#1e1c1b",
          profile_color_2: @member.profile_color_2.presence || @member.profile_color || "#1e1c1b",
          avatar_url: avatar_url,
          banner_url: banner_url,
          banner_offset_y: @member.banner_offset_y || 0,
          roles: roles,
          member_since: membership&.joined_at&.strftime("%b %d, %Y"),
          account_created: @member.created_at.strftime("%b %d, %Y")
        }
      end
    end
  end
end
