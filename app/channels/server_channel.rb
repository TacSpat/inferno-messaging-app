class ServerChannel < ApplicationCable::Channel
  def subscribed
    @server = Server.find_by!(public_id: params[:server_id])
    stream_for @server
    send_presence_sync
    send_voice_state_sync
  end

  def unsubscribed
  end

  private

  def send_presence_sync
    members = @server.members.where.not(online_state: :offline)
                     .select(:public_id, :online_state)
    states = members.map { |m| { user_id: m.public_id, state: m.online_state } }

    # Include remote members so their presence isn't reset to offline on refresh
    remote = @server.remote_members.where.not(online_state: :offline)
                    .select(:public_id, :online_state)
    remote.each { |rm| states << { user_id: rm.public_id, state: rm.online_state } }

    transmit({ type: "presence_sync", members: states })
  end

  # Send current voice channel participants so late-connecting clients
  # see who's in voice without needing a page refresh
  def send_voice_state_sync
    voice_states = []

    @server.voice_states.includes(:user, :channel).each do |vs|
      voice_states << {
        channel_id: vs.channel.public_id,
        user_id: vs.user.public_id,
        voice_state_id: vs.public_id,
        username: vs.user.display_name.presence || vs.user.username,
        avatar_url: vs.user.effective_avatar_url,
        profile_color: vs.user.profile_color,
        self_mute: vs.self_mute,
        self_deaf: vs.self_deaf
      }
    end

    # Include remote voice states from relay cache
    @server.channels.voice.each do |channel|
      RelaySubscriptionManager.remote_voice_states(channel.public_id).each_value do |rvs|
        voice_states << {
          channel_id: channel.public_id,
          user_id: rvs[:user_id],
          username: rvs[:username] || "Remote User",
          avatar_url: rvs[:avatar_url],
          profile_color: rvs[:profile_color],
          remote: true
        }
      end
    end

    transmit({ type: "voice_state_sync", voice_states: voice_states }) if voice_states.any?
  end
end
