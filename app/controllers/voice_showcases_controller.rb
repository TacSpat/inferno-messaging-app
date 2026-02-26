class VoiceShowcasesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :ensure_member!

  # POST /servers/:server_id/voice_showcases
  # Start a showcase (hearth user initiates)
  def create
    parent_channel = @server.channels.voice.find_by!(public_id: params[:parent_channel_id])
    child_channel = @server.channels.voice.find_by!(public_id: params[:child_channel_id])

    # Verify user is in the hearth channel
    voice_state = VoiceState.find_by(user: current_user, server: @server)
    unless voice_state&.channel_id == parent_channel.id
      render json: { error: "You must be in the hearth channel" }, status: :forbidden
      return
    end

    # Verify ember is actually nested under this hearth
    unless child_channel.parent_channel_id == parent_channel.id
      render json: { error: "Channel is not an ember of this hearth" }, status: :unprocessable_entity
      return
    end

    showcased_user = params[:user_id].present? ? User.find_by!(public_id: params[:user_id]) : nil

    showcase = VoiceShowcase.create!(
      server: @server,
      parent_channel: parent_channel,
      child_channel: child_channel,
      user: showcased_user,
      approved_by: current_user
    )

    render json: { showcase_id: showcase.public_id }
  end

  # DELETE /servers/:server_id/voice_showcases/:id
  def destroy
    showcase = VoiceShowcase.find_by!(public_id: params[:id], server: @server)
    showcase.destroy
    render json: { success: true }
  end

  # POST /servers/:server_id/voice_showcases/request_speak
  # Ember user requests to speak at hearth level
  def request_speak
    voice_state = VoiceState.find_by(user: current_user, server: @server)
    unless voice_state
      render json: { error: "Not in a voice channel" }, status: :unprocessable_entity
      return
    end

    channel = voice_state.channel
    unless channel.parent_channel_id.present?
      render json: { error: "Your channel has no hearth" }, status: :unprocessable_entity
      return
    end

    # Broadcast request to hearth channel users
    ServerChannel.broadcast_to(@server, {
      type: "voice_speak_request",
      child_channel_id: channel.public_id,
      child_channel_name: channel.name,
      parent_channel_id: channel.parent_channel.public_id,
      user_id: current_user.public_id,
      username: current_user.display_name.presence || current_user.username,
      avatar_url: current_user.effective_avatar_url
    })

    render json: { success: true }
  end

  # POST /servers/:server_id/voice_showcases/:id/approve
  def approve
    # Find the pending request context from params
    child_channel = @server.channels.voice.find_by!(public_id: params[:child_channel_id])
    parent_channel = child_channel.parent_channel

    unless parent_channel
      render json: { error: "Channel has no hearth" }, status: :unprocessable_entity
      return
    end

    # Verify approver is in the hearth channel
    voice_state = VoiceState.find_by(user: current_user, server: @server)
    unless voice_state&.channel_id == parent_channel.id
      render json: { error: "You must be in the hearth channel" }, status: :forbidden
      return
    end

    showcased_user = User.find_by!(public_id: params[:user_id])

    showcase = VoiceShowcase.create!(
      server: @server,
      parent_channel: parent_channel,
      child_channel: child_channel,
      user: showcased_user,
      approved_by: current_user
    )

    # Notify the requesting user
    ServerChannel.broadcast_to(@server, {
      type: "voice_speak_request_approved",
      showcase_id: showcase.public_id,
      child_channel_id: child_channel.public_id,
      parent_channel_id: parent_channel.public_id,
      user_id: showcased_user.public_id
    })

    render json: { showcase_id: showcase.public_id }
  end

  # POST /servers/:server_id/voice_showcases/:id/deny
  def deny
    child_channel = @server.channels.voice.find_by!(public_id: params[:child_channel_id])
    denied_user = User.find_by!(public_id: params[:user_id])

    ServerChannel.broadcast_to(@server, {
      type: "voice_speak_request_denied",
      child_channel_id: child_channel.public_id,
      user_id: denied_user.public_id
    })

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
end
