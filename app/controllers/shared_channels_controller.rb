class SharedChannelsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_channel
  before_action :authorize_manage!

  # POST /servers/:server_id/channels/:id/bridge
  # Enable sharing or bridge to an external NIP-29 group
  def bridge
    relay_url = params[:relay_url]&.strip
    group_id = params[:group_id]&.strip.presence

    if relay_url.blank?
      redirect_to edit_server_channel_path(@server, @channel), alert: "Relay URL is required."
      return
    end

    if group_id.present?
      # Bridge to external group
      @channel.bridge_to!(relay_url: relay_url, group_id: group_id)
    else
      # Enable sharing (create new group)
      @channel.enable_sharing!(relay_url: relay_url)
    end

    # Start subscription for inbound messages
    NostrGroupSubscriptionJob.perform_later

    redirect_to server_channel_path(@server, @channel),
      notice: "Channel is now shared via NIP-29 group #{@channel.nostr_group_id}."
  end

  # DELETE /servers/:server_id/channels/:id/unbridge
  # Disable sharing
  def unbridge
    @channel.unbridge!
    redirect_to server_channel_path(@server, @channel),
      notice: "Channel sharing has been disabled."
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def set_channel
    @channel = @server.channels.find_by!(public_id: params[:id])
  end

  def authorize_manage!
    # Single-user app: owner is always authorized
  end
end
