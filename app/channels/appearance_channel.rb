class AppearanceChannel < ApplicationCable::Channel
  def subscribed
    # Small delay so other subscriptions establish first
    current_user.update_columns(online_state: User.online_states[:online], online_at: Time.current)
    # Broadcast after a tick so ServerChannel subscriptions are ready
    broadcast_presence_later("online")
  end

  def unsubscribed
    AppearanceOfflineJob.set(wait: 5.seconds).perform_later(current_user.id)
  end

  def away
    current_user.update_columns(online_state: User.online_states[:idle], online_at: Time.current)
    broadcast_presence("idle")
  end

  def back
    current_user.update_columns(online_state: User.online_states[:online], online_at: Time.current)
    broadcast_presence("online")
  end

  private

  def broadcast_presence_later(state)
    Thread.new do
      sleep 0.5
      broadcast_presence(state)
    end
  end

  def broadcast_presence(state)
    current_user.servers.each do |server|
      ServerChannel.broadcast_to(server, {
        type: "presence",
        user_id: current_user.public_id,
        state: state
      })
    end
  end
end
