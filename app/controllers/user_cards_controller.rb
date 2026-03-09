class UserCardsController < ApplicationController
  before_action :authenticate_user!

  def show
    @member = User.includes(avatar_attachment: :blob, banner_attachment: :blob)
                  .find_by(public_id: params[:id])

    if params[:server_id].present?
      @server = Server.find_by(public_id: params[:server_id])
    end

    # Fall back to RemoteMember if no local User found
    if @member.nil? && @server
      @member = @server.remote_members.find_by(public_id: params[:id])
    elsif @member.nil?
      # Search across all servers for the remote member
      @member = RemoteMember.find_by(public_id: params[:id])
      @server ||= @member&.server
    end

    # Fall back to pubkey-based lookup (for DM messages from remote users)
    if @member.nil?
      @member = RemoteMember.where(pubkey: params[:id]).order(updated_at: :desc).first
      @server ||= @member&.server
    end

    return head(:not_found) unless @member

    respond_to do |format|
      format.html do
        render partial: "users/card", locals: { member: @member, server: @server }, layout: false
      end
      format.json do
        is_remote = @member.is_a?(RemoteMember)

        if is_remote
          roles = @member.roles.where.not(name: "@everyone").ordered.map do |r|
            { name: r.name, color: r.color || "#ffffff" }
          end
        else
          membership = @server&.server_memberships&.find_by(user: @member)
          roles = membership&.roles&.where&.not(name: "@everyone")&.ordered&.map do |r|
            { name: r.name, color: r.color || "#ffffff" }
          end || []
        end

        avatar_url = @member.try(:effective_avatar_url) || @member.try(:avatar_url)
        banner_url = @member.try(:effective_banner_url) || @member.try(:banner_url)

        member_pubkey = @member.try(:nostr_public_key) || @member.try(:pubkey)
        contact = Contact.find_by(pubkey: member_pubkey) if member_pubkey.present?

        render json: {
          public_id: @member.public_id,
          username: @member.try(:username) || @member.try(:display_name) || "Unknown",
          display_name: @server ? @member.display_name_for(@server) : (@member.try(:display_name).presence || @member.try(:username) || "Unknown"),
          tag: @member.try(:tag) || "Unknown#0000",
          bio: @member.try(:bio),
          status: @member.try(:status),
          status_emoji: @member.try(:status_emoji),
          online_state: @member.try(:online_state) || "offline",
          profile_color: @member.try(:profile_color) || "#1e1c1b",
          profile_color_2: @member.try(:profile_color_2).presence || @member.try(:profile_color) || "#1e1c1b",
          avatar_url: avatar_url,
          banner_url: banner_url,
          banner_offset_y: @member.try(:banner_offset_y) || 0,
          roles: roles,
          member_since: is_remote ? @member.joined_at&.strftime("%b %d, %Y") : membership&.joined_at&.strftime("%b %d, %Y"),
          account_created: @member.created_at.strftime("%b %d, %Y"),
          remote: is_remote,
          friendship_status: contact&.friendship_status || "none",
          contact_id: contact&.id,
          nostr_pubkey: member_pubkey,
          is_self: @member.is_a?(User) && @member.id == current_user.id
        }
      end
    end
  end
end
