class VoiceState < ApplicationRecord
  include HasPublicId

  belongs_to :user
  belongs_to :channel
  belongs_to :server

  before_validation :generate_session_id, on: :create

  validates :user_id, uniqueness: { scope: :server_id, message: "is already in a voice channel on this server" }
  validates :session_id, presence: true, uniqueness: true

  after_create_commit :broadcast_join, :sync_join_to_remote
  after_destroy_commit :broadcast_leave, :sync_leave_to_remote
  after_destroy_commit :clear_channel_provider_if_empty

  def broadcast_join
    ServerChannel.broadcast_to(server, {
      type: "voice_state_join",
      channel_id: channel.public_id,
      user_id: user.public_id,
      voice_state_id: public_id,
      username: user.display_name.presence || user.username,
      avatar_url: user.effective_avatar_url,
      profile_color: user.profile_color
    })
  rescue => e
    Rails.logger.error "[VoiceState] broadcast_join failed: #{e.message}"
  end

  def broadcast_leave
    ServerChannel.broadcast_to(server, {
      type: "voice_state_leave",
      channel_id: channel.public_id,
      user_id: user.public_id
    })
  rescue => e
    Rails.logger.error "[VoiceState] broadcast_leave failed: #{e.message}"
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
      screen_share_on: screen_share_on,
      broadcasting: broadcasting
    })
  rescue => e
    Rails.logger.error "[VoiceState] broadcast_update failed: #{e.message}"
  end

  private

  def generate_session_id
    self.session_id ||= SecureRandom.uuid
  end

  def sync_join_to_remote
    NostrVoiceStateSyncJob.perform_later(
      "join", server_id, channel.public_id,
      user.public_id,
      user.display_name.presence || user.username,
      user.effective_avatar_url,
      user.profile_color
    )
  rescue => e
    Rails.logger.error "[VoiceState] sync_join_to_remote failed: #{e.message}"
  end

  def sync_leave_to_remote
    NostrVoiceStateSyncJob.perform_later(
      "leave", server_id, channel.public_id,
      user.public_id, nil, nil, nil
    )
  rescue => e
    Rails.logger.error "[VoiceState] sync_leave_to_remote failed: #{e.message}"
  end

  def clear_channel_provider_if_empty
    return unless channel.voice_states.none?
    channel.update_column(:current_voice_provider_id, nil)
  end
end
