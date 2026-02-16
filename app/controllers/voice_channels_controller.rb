class VoiceChannelsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_channel
  before_action :ensure_member!

  def join
    membership = current_user.server_memberships.find_by(server: @server)
    unless membership&.has_permission?("connect_voice")
      return render json: { error: "You don't have permission to join voice channels" }, status: :forbidden
    end

    # Leave any existing voice channel in this server
    existing = VoiceState.find_by(user: current_user, server: @server)
    if existing
      broadcast_voice_leave(existing)
      existing.destroy!
    end

    session_id = SecureRandom.uuid

    # Check user limit
    if @channel.voice_user_limit > 0 && @channel.voice_states.count >= @channel.voice_user_limit
      return render json: { error: "This voice channel is full" }, status: :unprocessable_entity
    end

    # Determine permissions for token
    can_speak = membership.has_permission?("speak")
    begin
      token = LivekitTokenService.generate_token(
        user: current_user,
        channel: @channel,
        permissions: { speak: can_speak }
      )
    rescue LivekitTokenService::TokenError => e
      return render json: { error: "Voice is not configured: #{e.message}" }, status: :service_unavailable
    end

    voice_state = VoiceState.create!(
      user: current_user,
      channel: @channel,
      server: @server,
      session_id: session_id
    )

    sidebar_html = render_to_string(
      partial: "voice_states/participant",
      locals: { voice_state: voice_state },
      formats: [:html]
    )

    broadcast_voice_join(voice_state, sidebar_html)

    render json: {
      token: token,
      url: LivekitTokenService.livekit_url,
      session_id: session_id,
      voice_state_id: voice_state.public_id,
      channel_id: @channel.public_id,
      user_id: current_user.public_id,
      username: current_user.display_name.presence || current_user.username,
      avatar_url: current_user.avatar.attached? ? url_for(current_user.avatar) : nil,
      profile_color: current_user.profile_color || "#2b2d31",
      sidebar_html: sidebar_html
    }
  end

  # Returns a fresh token without creating/destroying voice state
  # Used on page reload when user is already in a voice channel
  def refresh_token
    voice_state = VoiceState.find_by(user: current_user, channel: @channel, server: @server)
    unless voice_state
      return render json: { error: "Not in this voice channel" }, status: :not_found
    end

    membership = current_user.server_memberships.find_by(server: @server)
    can_speak = membership&.has_permission?("speak")

    begin
      token = LivekitTokenService.generate_token(
        user: current_user,
        channel: @channel,
        permissions: { speak: can_speak }
      )
    rescue LivekitTokenService::TokenError => e
      return render json: { error: "Voice is not configured: #{e.message}" }, status: :service_unavailable
    end

    render json: {
      token: token,
      url: LivekitTokenService.livekit_url
    }
  end

  def leave
    voice_state = VoiceState.find_by(user: current_user, server: @server)
    if voice_state
      broadcast_voice_leave(voice_state)
      voice_state.destroy!
    end

    head :ok
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def set_channel
    @channel = @server.channels.find_by!(public_id: params[:id])
  end

  def ensure_member!
    unless current_user.servers.include?(@server)
      render json: { error: "You're not a member of this server" }, status: :forbidden
    end
  end

  def broadcast_voice_join(voice_state, sidebar_html)
    ServerChannel.broadcast_to(@server, {
      type: "voice_state_join",
      channel_id: @channel.public_id,
      user_id: current_user.public_id,
      username: current_user.display_name.presence || current_user.username,
      voice_state_id: voice_state.public_id,
      self_mute: voice_state.self_mute,
      self_deaf: voice_state.self_deaf,
      avatar_url: current_user.avatar.attached? ? url_for(current_user.avatar) : nil,
      profile_color: current_user.profile_color || "#2b2d31",
      html: sidebar_html
    })
  end

  def broadcast_voice_leave(voice_state)
    ServerChannel.broadcast_to(@server, {
      type: "voice_state_leave",
      channel_id: voice_state.channel.public_id,
      user_id: voice_state.user.public_id
    })
  end
end
