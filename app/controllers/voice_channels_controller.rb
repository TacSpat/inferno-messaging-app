class VoiceChannelsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :ensure_member!
  skip_forgery_protection only: :leave  # sendBeacon can't send CSRF headers

  # POST /servers/:server_id/voice/join/:channel_id
  def join
    unless @server.voice_ready?
      render json: { error: "No voice providers available. A server member needs to volunteer their LiveKit credentials." }, status: :service_unavailable
      return
    end

    @channel = @server.channels.find_by!(public_id: params[:channel_id])

    unless @channel.voice?
      render json: { error: "This is not a voice channel" }, status: :unprocessable_entity
      return
    end

    membership = current_user.server_memberships.find_by(server: @server)
    unless membership&.has_permission?("connect_voice")
      render json: { error: "You don't have permission to join voice channels" }, status: :forbidden
      return
    end

    # Check user limit
    if @channel.voice_user_limit > 0 && @channel.voice_states.count >= @channel.voice_user_limit
      render json: { error: "This voice channel is full" }, status: :unprocessable_entity
      return
    end

    # Resolve provider: use channel's current if valid, else pick new one
    svp = resolve_voice_provider(@channel)
    unless svp
      render json: { error: "No voice providers available" }, status: :service_unavailable
      return
    end

    # Get the token first (may involve remote RPC), before creating voice state
    if svp.local?
      provider = svp.user
      # Assign provider to channel if new
      @channel.update_column(:current_voice_provider_id, provider.id) if @channel.current_voice_provider_id != provider.id

      token = LivekitTokenService.generate_token(
        user: current_user,
        channel: @channel,
        server: @server,
        provider: provider
      )
      livekit_url = provider.livekit_url
      provider_id = provider.public_id
    else
      result = VoiceTokenRpcService.request_token(
        provider_pubkey: svp.provider_pubkey,
        requesting_user: current_user,
        server: @server,
        channel: @channel
      )
      token = result[:token]
      livekit_url = result[:livekit_url]
      provider_id = svp.provider_pubkey[0..15]
    end

    # Only create voice state after successfully obtaining a token
    existing = VoiceState.find_by(user: current_user, server: @server)
    existing&.destroy

    voice_state = VoiceState.create!(
      user: current_user,
      channel: @channel,
      server: @server
    )

    # Generate subscribe-only tokens for ancestor rooms (audio cascades down)
    ancestor_rooms = @channel.ancestor_channels.filter_map do |ancestor|
      ancestor_svp = resolve_voice_provider(ancestor)
      next unless ancestor_svp&.local? && ancestor_svp.user&.livekit_configured?
      ancestor_provider = ancestor_svp.user
      ancestor_token = LivekitTokenService.generate_subscribe_only_token(
        user: current_user, channel: ancestor, server: @server, provider: ancestor_provider
      )
      {
        room_name: LivekitTokenService.room_name_for(@server, ancestor),
        token: ancestor_token,
        livekit_url: ancestor_provider.livekit_url,
        channel_id: ancestor.public_id,
        channel_name: ancestor.name
      }
    end

    # Include ember channels for monitor mode
    child_channels = @channel.child_channels.ordered.map do |c|
      { channel_id: c.public_id, name: c.name, participant_count: c.voice_states.count }
    end

    render json: {
      livekit_url: livekit_url,
      token: token,
      voice_state_id: voice_state.public_id,
      channel_id: @channel.public_id,
      channel_name: @channel.name,
      provider_id: provider_id,
      ancestor_rooms: ancestor_rooms,
      child_channels: child_channels
    }
  rescue LivekitTokenService::ConfigurationError => e
    render json: { error: e.message }, status: :service_unavailable
  rescue VoiceTokenRpcService::TimeoutError
    render json: { error: "Voice provider did not respond in time. Please try again." }, status: :gateway_timeout
  rescue VoiceTokenRpcService::RpcError => e
    render json: { error: e.message }, status: :service_unavailable
  end

  # POST /servers/:server_id/voice/rejoin/:channel_id
  # Called by client after unexpected disconnect for auto-failover
  def rejoin
    @channel = @server.channels.find_by!(public_id: params[:channel_id])

    unless @channel.voice?
      render json: { error: "This is not a voice channel" }, status: :unprocessable_entity
      return
    end

    # Exclude the failed provider
    exclude_ids = []
    if params[:exclude_provider].present?
      failed_user = User.find_by(public_id: params[:exclude_provider])
      exclude_ids << failed_user.id if failed_user
    end

    svp = @server.pick_voice_provider(exclude_ids: exclude_ids)
    unless svp
      render json: { error: "All voice providers are offline" }, status: :service_unavailable
      return
    end

    if svp.local?
      provider = svp.user
      @channel.update_column(:current_voice_provider_id, provider.id)

      token = LivekitTokenService.generate_token(
        user: current_user,
        channel: @channel,
        server: @server,
        provider: provider
      )
      livekit_url = provider.livekit_url
      provider_id = provider.public_id
    else
      result = VoiceTokenRpcService.request_token(
        provider_pubkey: svp.provider_pubkey,
        requesting_user: current_user,
        server: @server,
        channel: @channel
      )
      token = result[:token]
      livekit_url = result[:livekit_url]
      provider_id = svp.provider_pubkey[0..15]
    end

    # Generate subscribe-only tokens for ancestor rooms on rejoin
    ancestor_rooms = @channel.ancestor_channels.filter_map do |ancestor|
      ancestor_svp = resolve_voice_provider(ancestor)
      next unless ancestor_svp&.local? && ancestor_svp.user&.livekit_configured?
      ancestor_provider = ancestor_svp.user
      ancestor_token = LivekitTokenService.generate_subscribe_only_token(
        user: current_user, channel: ancestor, server: @server, provider: ancestor_provider
      )
      {
        room_name: LivekitTokenService.room_name_for(@server, ancestor),
        token: ancestor_token,
        livekit_url: ancestor_provider.livekit_url,
        channel_id: ancestor.public_id,
        channel_name: ancestor.name
      }
    end

    render json: {
      livekit_url: livekit_url,
      token: token,
      provider_id: provider_id,
      ancestor_rooms: ancestor_rooms
    }
  rescue LivekitTokenService::ConfigurationError => e
    render json: { error: e.message }, status: :service_unavailable
  rescue VoiceTokenRpcService::TimeoutError
    render json: { error: "Voice provider did not respond in time. Please try again." }, status: :gateway_timeout
  rescue VoiceTokenRpcService::RpcError => e
    render json: { error: e.message }, status: :service_unavailable
  end

  # DELETE /servers/:server_id/voice/leave
  # Also accepts POST for sendBeacon compatibility
  def leave
    voice_state = VoiceState.find_by(user: current_user, server: @server)

    if voice_state
      voice_state.destroy
    end

    render json: { success: true }
  end

  # POST /servers/:server_id/voice/monitor/:channel_id
  # Get a subscribe-only token for monitoring an ember channel
  def monitor
    child_channel = @server.channels.voice.find_by!(public_id: params[:channel_id])

    # Verify user is in a hearth/ancestor of this ember
    voice_state = VoiceState.find_by(user: current_user, server: @server)
    unless voice_state && child_channel.ancestor_channels.any? { |a| a.id == voice_state.channel_id }
      render json: { error: "Not in a hearth channel" }, status: :forbidden
      return
    end

    svp = resolve_voice_provider(child_channel)
    unless svp&.local? && svp.user&.livekit_configured?
      render json: { error: "No voice provider available for this channel" }, status: :service_unavailable
      return
    end

    provider = svp.user
    token = LivekitTokenService.generate_subscribe_only_token(
      user: current_user, channel: child_channel, server: @server, provider: provider
    )

    render json: {
      token: token,
      livekit_url: provider.livekit_url,
      room_name: LivekitTokenService.room_name_for(@server, child_channel),
      channel_id: child_channel.public_id,
      channel_name: child_channel.name
    }
  rescue LivekitTokenService::ConfigurationError => e
    render json: { error: e.message }, status: :service_unavailable
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def ensure_member!
    unless current_user.servers.include?(@server)
      render json: { error: "You're not a member of this server" }, status: :forbidden
    end
  end

  # Resolve which provider to use for a channel.
  # Returns a ServerVoiceProvider record.
  # If channel already has a valid active provider, use it.
  # Otherwise pick a new one via load balancing.
  def resolve_voice_provider(channel)
    if channel.current_voice_provider_id.present?
      svp = @server.server_voice_providers.active.find_by(user_id: channel.current_voice_provider_id)
      return svp if svp&.local? && svp.user&.livekit_configured?
    end

    @server.pick_voice_provider
  end
end
