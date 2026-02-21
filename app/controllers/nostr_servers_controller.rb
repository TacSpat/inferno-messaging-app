class NostrServersController < ApplicationController
  layout "standalone"

  before_action :set_server_preview, only: [:show]

  def show
    respond_to do |format|
      format.html do
        @already_member = user_signed_in? && @local_server&.members&.include?(current_user)
      end
      format.json do
        if @local_server
          render json: {
            server_name: @local_server.name,
            description: @local_server.description,
            icon_url: @local_server.icon.attached? ? rails_blob_url(@local_server.icon) : nil,
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
    @nostr_group_id = params[:nostr_group_id]

    unless user_signed_in?
      session[:pending_nostr_server] = @nostr_group_id
      redirect_to new_user_session_path, notice: "Sign in to join this server!"
      return
    end

    server = Server.find_by(nostr_group_id: @nostr_group_id)

    # Already a member — just go there
    if server && current_user.servers.include?(server)
      redirect_to server_channel_path(server, server.channels.ordered.first)
      return
    end

    # Kick off async sync and render loading page
    cache_key = "nostr_sync:#{@nostr_group_id}:#{current_user.id}"
    Rails.cache.write(cache_key, { step: "starting", progress: 0 }, expires_in: 5.minutes)
    NostrServerJoinJob.perform_later(@nostr_group_id, current_user.id)

    render :syncing
  end

  def sync_status
    nostr_group_id = params[:nostr_group_id]
    cache_key = "nostr_sync:#{nostr_group_id}:#{current_user.id}"
    status = Rails.cache.read(cache_key) || { step: "waiting", progress: 0 }

    # If complete, include the redirect URL
    if status[:step] == "complete"
      server = Server.find_by(nostr_group_id: nostr_group_id)
      if server
        first_channel = server.channels.ordered.first
        status[:redirect_url] = first_channel ? "/servers/#{server.public_id}/channels/#{first_channel.public_id}" : "/"
      else
        status[:step] = "failed"
        status[:error] = "Server not found after sync"
      end
    end

    render json: status
  end

  private

  def set_server_preview
    @nostr_group_id = params[:nostr_group_id]
    @local_server = Server.find_by(nostr_group_id: @nostr_group_id)
    @instance_domain = Rails.application.config.x.instance_domain

    if @local_server
      @member_count = @local_server.members.count
      @online_count = @local_server.members.where(online_state: :online).count
      @server_name = @local_server.name
      @server_description = @local_server.description
    else
      @nostr_info = NostrServerSyncService.fetch_metadata_preview(@nostr_group_id) || {}
      @member_count = @nostr_info[:member_count] || 0
      @online_count = 0
      @server_name = @nostr_info[:name] || "Unknown Server"
      @server_description = @nostr_info[:about]
    end
  end
end
