class AppearanceChannel < ApplicationCable::Channel
  def subscribed
    current_user.update_columns(online_state: User.online_states[:online], online_at: Time.current)
    broadcast_presence_later("online")
    publish_nostr_status("online")
  end

  def unsubscribed
    AppearanceOfflineJob.set(wait: 45.seconds).perform_later(current_user.id)
  end

  def ping(data = {})
    state = data["state"] == "idle" ? :idle : :online
    current_user.update_columns(online_state: User.online_states[state], online_at: Time.current)
  end

  def away
    current_user.update_columns(online_state: User.online_states[:idle], online_at: Time.current)
    broadcast_presence("idle")
    publish_nostr_status("idle")
  end

  def back
    current_user.update_columns(online_state: User.online_states[:online], online_at: Time.current)
    broadcast_presence("online")
    publish_nostr_status("online")
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
  end

  # Publish NIP-38 Kind 30315 user status event to relays
  def publish_nostr_status(state)
    return unless current_user.nostr_public_key.present?
    NostrPresencePublishJob.perform_later(current_user.id, state)
  end
end
