class NostrServersController < ApplicationController
  before_action :set_server_data

  def show
    respond_to do |format|
      format.html do
        @already_member = user_signed_in? && @server&.members&.include?(current_user)
      end
      format.json do
        if @server
          render json: {
            server_name: @server.name,
            description: @server.description,
            icon_url: @server.icon.attached? ? rails_blob_url(@server.icon) : nil,
            member_count: @member_count,
            online_count: @online_count,
            nostr_group_id: @nostr_group_id
          }
        else
          render json: {
            server_name: @nostr_info[:name],
            description: @nostr_info[:about],
            icon_url: @nostr_info[:picture_url],
            member_count: @member_count,
            online_count: 0,
            nostr_group_id: @nostr_group_id
          }
        end
      end
    end
  end

  def join
    unless user_signed_in?
      session[:pending_nostr_server] = @nostr_group_id
      redirect_to new_user_session_path, notice: "Sign in to join this server!"
      return
    end

    if @server && current_user.servers.include?(@server)
      redirect_to server_channel_path(@server, @server.channels.ordered.first)
      return
    end

    # Bootstrap from Nostr relays if server doesn't exist locally
    unless @server
      NostrServerSyncService.new(@nostr_group_id, joining_user: current_user).sync_all
      @server = Server.find_by(nostr_group_id: @nostr_group_id)
    end

    unless @server
      redirect_to root_path, alert: "Could not find or bootstrap this server from Nostr relays."
      return
    end

    # Sync latest state if server already existed
    if current_user.servers.include?(@server)
      redirect_to server_channel_path(@server, @server.channels.ordered.first)
      return
    end

    NostrServerSyncService.new(@nostr_group_id, joining_user: current_user).sync_all
    @server.server_memberships.create!(user: current_user)

    # Publish self-join member event to Nostr
    if current_user.nostr_public_key.present?
      NostrServerPublishJob.perform_later(current_user.id, @server.id, "member", pubkey: current_user.nostr_public_key)
    end

    redirect_to server_channel_path(@server, @server.channels.ordered.first), notice: "Welcome to #{@server.name}!"
  end

  private

  def set_server_data
    @nostr_group_id = params[:nostr_group_id]
    @server = Server.find_by(nostr_group_id: @nostr_group_id)
    @instance_domain = Rails.application.config.x.instance_domain

    if @server
      @member_count = @server.members.count
      @online_count = @server.members.where(online_state: :online).count
      @server_name = @server.name
      @server_description = @server.description
    else
      @nostr_info = NostrServerSyncService.fetch_metadata_preview(@nostr_group_id) || {}
      @member_count = @nostr_info[:member_count] || 0
      @online_count = 0
      @server_name = @nostr_info[:name] || "Unknown Server"
      @server_description = @nostr_info[:about]
    end
  end
end
