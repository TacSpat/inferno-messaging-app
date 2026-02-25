class VoiceStatesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_voice_state

  # PATCH /voice_states/self_mute
  def self_mute
    @voice_state.update!(self_mute: params[:muted] == true || params[:muted] == "true")
    @voice_state.broadcast_update
    render json: { success: true, self_mute: @voice_state.self_mute }
  end

  # PATCH /voice_states/self_deafen
  def self_deafen
    deafened = params[:deafened] == true || params[:deafened] == "true"
    attrs = { self_deaf: deafened }
    # Deafening also mutes
    attrs[:self_mute] = true if deafened
    @voice_state.update!(attrs)
    @voice_state.broadcast_update
    render json: { success: true, self_deaf: @voice_state.self_deaf, self_mute: @voice_state.self_mute }
  end

  # PATCH /voice_states/screen_share
  def screen_share
    @voice_state.update!(screen_share_on: params[:screen_share] == true || params[:screen_share] == "true")
    @voice_state.broadcast_update
    render json: { success: true, screen_share_on: @voice_state.screen_share_on }
  end

  # PATCH /voice_states/video
  def video
    @voice_state.update!(video_on: params[:video] == true || params[:video] == "true")
    @voice_state.broadcast_update
    render json: { success: true, video_on: @voice_state.video_on }
  end

  private

  def set_voice_state
    @voice_state = VoiceState.find_by!(user: current_user)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Not in a voice channel" }, status: :not_found
  end
end
