class VoiceShowcase < ApplicationRecord
  include HasPublicId

  belongs_to :server
  belongs_to :parent_channel, class_name: "Channel"
  belongs_to :child_channel, class_name: "Channel"
  belongs_to :user, optional: true
  belongs_to :approved_by, class_name: "User", optional: true

  after_create_commit :broadcast_start
  after_destroy_commit :broadcast_end

  private

  def broadcast_start
    ServerChannel.broadcast_to(server, {
      type: "voice_showcase_start",
      showcase_id: public_id,
      parent_channel_id: parent_channel.public_id,
      child_channel_id: child_channel.public_id,
      user_id: user&.public_id,
      username: user&.display_name.presence || user&.username
    })
  rescue => e
    Rails.logger.error "[VoiceShowcase] broadcast_start failed: #{e.message}"
  end

  def broadcast_end
    ServerChannel.broadcast_to(server, {
      type: "voice_showcase_end",
      showcase_id: public_id,
      parent_channel_id: parent_channel.public_id,
      child_channel_id: child_channel.public_id,
      user_id: user&.public_id
    })
  rescue => e
    Rails.logger.error "[VoiceShowcase] broadcast_end failed: #{e.message}"
  end
end
