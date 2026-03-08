class AfkVoiceCheckJob < ApplicationJob
  queue_as :default

  def perform
    Server.where(voice_enabled: true)
          .where.not(afk_timeout: 0)
          .where(id: VoiceState.select(:server_id).distinct)
          .find_each do |server|

      cutoff = server.afk_timeout.minutes.ago

      server.voice_states.includes(:user, :channel).find_each do |vs|
        user = vs.user
        next unless user.idle? || user.offline?
        next unless user.online_at.present? && user.online_at < cutoff
        next if vs.channel_id == server.afk_channel_id

        case server.afk_action
        when "move"
          next unless server.afk_channel_id.present?
          afk_channel = server.afk_channel
          next unless afk_channel&.voice?

          from_channel_id = vs.channel.public_id
          vs.update!(channel: afk_channel, self_mute: true)

          ServerChannel.broadcast_to(server, {
            type: "voice_state_moved",
            user_id: user.public_id,
            from_channel_id: from_channel_id,
            to_channel_id: afk_channel.public_id,
            to_channel_name: afk_channel.name,
            voice_state_id: vs.public_id,
            username: user.display_name.presence || user.username,
            avatar_url: user.effective_avatar_url,
            profile_color: user.profile_color,
            self_mute: true,
            afk: true
          })
        when "kick"
          channel_id = vs.channel.public_id
          user_id = user.public_id
          vs.destroy

          ServerChannel.broadcast_to(server, {
            type: "voice_kicked",
            channel_id: channel_id,
            user_id: user_id,
            reason: "afk"
          })
        end
      end
    end

    self.class.set(wait: 1.minute).perform_later
  end
end
