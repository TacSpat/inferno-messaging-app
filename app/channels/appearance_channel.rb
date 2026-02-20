class AppearanceChannel < ApplicationCable::Channel
  def subscribed
    # Small delay so other subscriptions establish first
    current_user.update_columns(online_state: User.online_states[:online], online_at: Time.current)
    # Broadcast after a tick so ServerChannel subscriptions are ready
    broadcast_presence_later("online")
  end

  def unsubscribed
    # Wait long enough for a client ping cycle (30s) to distinguish
    # a brief WebSocket drop from actually leaving the page
    AppearanceOfflineJob.set(wait: 45.seconds).perform_later(current_user.id)
  end

  def ping(data = {})
    state = data["state"] == "idle" ? :idle : :online
    current_user.update_columns(online_state: User.online_states[state], online_at: Time.current)
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
    payload = { type: "presence", user_id: current_user.public_id, state: state }

    current_user.servers.each do |server|
      ServerChannel.broadcast_to(server, payload)
    end

    current_user.conversations.each do |conversation|
      ConversationChannel.broadcast_to(conversation, payload)
    end

    # Push to friends' notification streams so DM sidebar dots update
    current_user.friends.select(:id).each do |friend|
      ActionCable.server.broadcast("user_notifications_#{friend.id}", payload)
    end
  end
end
