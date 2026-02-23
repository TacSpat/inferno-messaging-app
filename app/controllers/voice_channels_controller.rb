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
    provider = resolve_provider(@channel)
    unless provider
      render json: { error: "No voice providers available" }, status: :service_unavailable
      return
    end

    # Assign provider to channel if new
    @channel.update_column(:current_voice_provider_id, provider.id) if @channel.current_voice_provider_id != provider.id

    # Remove any existing voice state for this user on this server
    existing = VoiceState.find_by(user: current_user, server: @server)
    existing&.destroy

    # Create new voice state
    voice_state = VoiceState.create!(
      user: current_user,
      channel: @channel,
      server: @server
    )

    # Generate LiveKit token using provider's credentials
    token = LivekitTokenService.generate_token(
      user: current_user,
      channel: @channel,
      server: @server,
      provider: provider
    )

    render json: {
      livekit_url: provider.livekit_url,
      token: token,
      voice_state_id: voice_state.public_id,
      channel_id: @channel.public_id,
      channel_name: @channel.name,
      provider_id: provider.public_id
    }
  rescue LivekitTokenService::ConfigurationError => e
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

    provider = @server.pick_voice_provider(exclude_ids: exclude_ids)
    unless provider
      render json: { error: "All voice providers are offline" }, status: :service_unavailable
      return
    end

    # Update channel's provider
    @channel.update_column(:current_voice_provider_id, provider.id)

    token = LivekitTokenService.generate_token(
      user: current_user,
      channel: @channel,
      server: @server,
      provider: provider
    )

    render json: {
      livekit_url: provider.livekit_url,
      token: token,
      provider_id: provider.public_id
    }
  rescue LivekitTokenService::ConfigurationError => e
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
  # If channel already has a valid active provider, use it.
  # Otherwise pick a new one via load balancing.
  def resolve_provider(channel)
    if channel.current_voice_provider_id.present?
      # Check the current provider is still active for this server
      svp = @server.server_voice_providers.active.find_by(user_id: channel.current_voice_provider_id)
      return svp.user if svp&.user&.livekit_configured?
    end

    @server.pick_voice_provider
  end
end
