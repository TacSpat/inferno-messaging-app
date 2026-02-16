class VoiceStatesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_own_voice_state, only: [:self_mute, :self_deafen]
  before_action :set_target_voice_state, only: [:context_menu, :server_mute, :server_deafen, :kick, :move]

  # --- Self-actions (existing) ---

  def self_mute
    @voice_state.update!(self_mute: !@voice_state.self_mute)
    broadcast_state_update(@voice_state)
    render json: { self_mute: @voice_state.self_mute }
  end

  def self_deafen
    if !@voice_state.self_deaf
      @voice_state.update!(self_deaf: true, self_mute: true)
    else
      @voice_state.update!(self_deaf: false)
    end
    broadcast_state_update(@voice_state)
    render json: { self_mute: @voice_state.self_mute, self_deaf: @voice_state.self_deaf }
  end

  # --- Context menu ---

  def context_menu
    @server = @voice_state.server
    @my_membership = @server.server_memberships.find_by(user: current_user)
    @voice_channels = @server.channels.where(channel_type: :voice).where.not(id: @voice_state.channel_id)

    render partial: "voice_states/voice_context_menu", locals: {
      voice_state: @voice_state,
      server: @server,
      my_membership: @my_membership,
      voice_channels: @voice_channels
    }
  end

  # --- Moderation actions ---

  def server_mute
    server = @voice_state.server
    is_self = @voice_state.user == current_user

    unless is_self || authorized?(server, "mute_members")
      return render json: { error: "Missing permission" }, status: :forbidden
    end

    @voice_state.update!(server_mute: !@voice_state.server_mute)
    broadcast_state_update(@voice_state)
    render json: { server_mute: @voice_state.server_mute }
  end

  def server_deafen
    server = @voice_state.server
    is_self = @voice_state.user == current_user

    unless is_self || authorized?(server, "deafen_members")
      return render json: { error: "Missing permission" }, status: :forbidden
    end

    if !@voice_state.server_deaf
      @voice_state.update!(server_deaf: true, server_mute: true)
    else
      @voice_state.update!(server_deaf: false)
    end
    broadcast_state_update(@voice_state)
    render json: { server_mute: @voice_state.server_mute, server_deaf: @voice_state.server_deaf }
  end

  def kick
    server = @voice_state.server
    channel = @voice_state.channel
    user = @voice_state.user
    is_self = user == current_user

    unless is_self || authorized?(server, "move_members")
      return render json: { error: "Missing permission" }, status: :forbidden
    end

    # Remove from LiveKit
    begin
      LivekitRoomService.remove_participant(channel: channel, identity: user.public_id)
    rescue LivekitRoomService::RoomError => e
      Rails.logger.warn("LiveKit remove_participant failed: #{e.message}")
    end

    @voice_state.destroy!

    ServerChannel.broadcast_to(server, {
      type: "voice_state_kicked",
      channel_id: channel.public_id,
      user_id: user.public_id
    })

    head :ok
  end

  def move
    server = @voice_state.server

    unless authorized?(server, "move_members")
      return render json: { error: "Missing permission" }, status: :forbidden
    end

    target_channel = server.channels.find_by!(public_id: params[:target_channel_id], channel_type: :voice)
    from_channel = @voice_state.channel
    user = @voice_state.user

    # Remove from old LiveKit room
    begin
      LivekitRoomService.remove_participant(channel: from_channel, identity: user.public_id)
    rescue LivekitRoomService::RoomError => e
      Rails.logger.warn("LiveKit remove_participant failed: #{e.message}")
    end

    @voice_state.update!(channel: target_channel)

    sidebar_html = render_to_string(
      partial: "voice_states/participant",
      locals: { voice_state: @voice_state },
      formats: [:html]
    )

    ServerChannel.broadcast_to(server, {
      type: "voice_state_moved",
      user_id: user.public_id,
      from_channel_id: from_channel.public_id,
      to_channel_id: target_channel.public_id,
      to_channel_name: target_channel.name,
      voice_state_id: @voice_state.public_id,
      html: sidebar_html
    })

    render json: { moved: true }
  end

  private

  def set_own_voice_state
    @voice_state = current_user.voice_states.first
    unless @voice_state
      render json: { error: "Not in a voice channel" }, status: :not_found
    end
  end

  def set_target_voice_state
    @voice_state = VoiceState.find_by!(public_id: params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Voice state not found" }, status: :not_found
  end

  def authorized?(server, permission)
    membership = server.server_memberships.find_by(user: current_user)
    membership&.has_permission?(permission) || membership&.owner?
  end

  def broadcast_state_update(voice_state)
    ServerChannel.broadcast_to(voice_state.server, {
      type: "voice_state_update",
      channel_id: voice_state.channel.public_id,
      user_id: voice_state.user.public_id,
      self_mute: voice_state.self_mute,
      self_deaf: voice_state.self_deaf,
      server_mute: voice_state.server_mute,
      server_deaf: voice_state.server_deaf
    })
  end
end
