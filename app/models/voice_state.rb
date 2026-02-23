class VoiceState < ApplicationRecord
  include HasPublicId

  belongs_to :user
  belongs_to :channel
  belongs_to :server

  before_validation :generate_session_id, on: :create

  validates :user_id, uniqueness: { scope: :server_id, message: "is already in a voice channel on this server" }
  validates :session_id, presence: true, uniqueness: true

  after_create_commit :broadcast_join
  after_destroy_commit :broadcast_leave
  after_destroy_commit :clear_channel_provider_if_empty

  def broadcast_join
    ServerChannel.broadcast_to(server, {
      type: "voice_state_join",
      channel_id: channel.public_id,
      user_id: user.public_id,
      voice_state_id: public_id,
      username: user.display_name.presence || user.username,
      avatar_url: user.effective_avatar_url,
      profile_color: user.profile_color,
      html: sidebar_participant_html
    })
  end

  def broadcast_leave
    ServerChannel.broadcast_to(server, {
      type: "voice_state_leave",
      channel_id: channel.public_id,
      user_id: user.public_id
    })
  end

  def broadcast_update
    ServerChannel.broadcast_to(server, {
      type: "voice_state_update",
      channel_id: channel.public_id,
      user_id: user.public_id,
      self_mute: self_mute,
      self_deaf: self_deaf,
      server_mute: server_mute,
      server_deaf: server_deaf,
      video_on: video_on,
      screen_share_on: screen_share_on
    })
  end

  private

  def generate_session_id
    self.session_id ||= SecureRandom.uuid
  end

  def clear_channel_provider_if_empty
    return unless channel.voice_states.none?
    channel.update_column(:current_voice_provider_id, nil)
  end

  def sidebar_participant_html
    ApplicationController.render(
      partial: "voice_states/sidebar_participant",
      locals: { voice_state: self }
    )
  end
end
