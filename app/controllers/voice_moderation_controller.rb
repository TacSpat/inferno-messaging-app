class VoiceModerationController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :ensure_member!

  # GET /servers/:server_id/voice/context_menu/:user_id
  def context_menu
    @target_user = User.find_by(public_id: params[:user_id])

    if @target_user.nil?
      # Remote user from another instance — show limited context menu
      render partial: "voice/remote_context_menu", locals: {
        user_id: params[:user_id],
        server: @server
      }, layout: false
      return
    end

    @voice_state = VoiceState.find_by(user: @target_user, server: @server)
    @my_membership = current_user.server_memberships.find_by(server: @server)
    render partial: "voice/context_menu", locals: {
      target_user: @target_user,
      voice_state: @voice_state,
      server: @server,
      my_membership: @my_membership,
      is_self: @target_user == current_user
    }, layout: false
  end

  # PATCH /servers/:server_id/voice/server_mute/:user_id
  def server_mute
    target = find_voice_state!
    return unless require_permission!("mute_members")

    target.update!(server_mute: !target.server_mute)
    target.broadcast_update
    render json: { success: true, server_mute: target.server_mute }
  end

  # PATCH /servers/:server_id/voice/server_deafen/:user_id
  def server_deafen
    target = find_voice_state!
    return unless require_permission!("deafen_members")

    target.update!(server_deaf: !target.server_deaf)
    target.broadcast_update
    render json: { success: true, server_deaf: target.server_deaf }
  end

  # DELETE /servers/:server_id/voice/disconnect/:user_id
  def disconnect_member
    target = find_voice_state!
    return unless require_permission!("move_members")

    channel_id = target.channel.public_id
    user_id = target.user.public_id
    target.destroy

    ServerChannel.broadcast_to(@server, {
      type: "voice_kicked",
      channel_id: channel_id,
      user_id: user_id
    })

    render json: { success: true }
  end

  # PATCH /servers/:server_id/voice/move/:user_id
  def move_member
    target = find_voice_state!
    return unless require_permission!("move_members")

    new_channel = @server.channels.find_by!(public_id: params[:channel_id])
    unless new_channel.voice?
      render json: { error: "Target is not a voice channel" }, status: :unprocessable_entity
      return
    end

    from_channel_id = target.channel.public_id
    target.update!(channel: new_channel)

    ServerChannel.broadcast_to(@server, {
      type: "voice_state_moved",
      user_id: target.user.public_id,
      from_channel_id: from_channel_id,
      to_channel_id: new_channel.public_id,
      to_channel_name: new_channel.name,
      voice_state_id: target.public_id,
      username: target.user.display_name.presence || target.user.username,
      avatar_url: target.user.effective_avatar_url,
      profile_color: target.user.profile_color
    })

    render json: { success: true }
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def ensure_member!
    unless current_user.servers.include?(@server)
      render json: { error: "Not a member" }, status: :forbidden
      nil
    end
  end

  def find_voice_state!
    target_user = User.find_by!(public_id: params[:user_id])
    vs = VoiceState.find_by!(user: target_user, server: @server)
    vs
  end

  def require_permission!(perm)
    membership = current_user.server_memberships.find_by(server: @server)
    unless membership&.has_permission?(perm) || membership&.owner?
      render json: { error: "Missing permission: #{perm}" }, status: :forbidden
      return false
    end
    true
  end
end
