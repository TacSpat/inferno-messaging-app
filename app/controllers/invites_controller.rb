class InvitesController < ApplicationController
  before_action :set_invite

  def show
    @server = @invite.server
    @member_count = @server.members.count
    @online_count = @server.members.where(online_state: :online).count
    @instance_domain = Rails.application.config.x.instance_domain

    respond_to do |format|
      format.html do
        @already_member = user_signed_in? && current_user.servers.include?(@server)
        @ban = user_signed_in? && @server.bans.find_by(user: current_user)
      end
      format.json do
        render json: {
          server_name: @server.name,
          description: @server.description,
          icon_url: @server.icon.attached? ? rails_blob_url(@server.icon) : nil,
          member_count: @member_count,
          online_count: @online_count,
          invite_code: @invite.code,
          nostr_group_id: @server.nostr_group_id,
          instance_domain: @instance_domain
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

    ban = @server.bans.find_by(user: current_user)
    if ban
      redirect_to invite_path(@invite.code), alert: "You are banned from this server."
      return
    end

    if current_user.servers.include?(@server)
      redirect_to server_channel_path(@server, @server.channels.ordered.first)
    else
      # Bootstrap server state from Nostr relays if this server has a nostr_group_id
      if @server.nostr_group_id.present?
        NostrServerSyncService.new(@server.nostr_group_id, joining_user: current_user).sync_all
      end

      @invite.increment_uses!
      @server.server_memberships.create!(user: current_user)

      # Publish self-join member event to Nostr
      if current_user.nostr_public_key.present?
        NostrServerPublishJob.perform_later(current_user.id, @server.id, "member", pubkey: current_user.nostr_public_key)
      end

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
