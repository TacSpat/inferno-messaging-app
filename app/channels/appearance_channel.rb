class AppearanceChannel < ApplicationCable::Channel
  MANUAL_STATES = %w[dnd invisible].freeze

  def subscribed
    manual = params[:manual_status].to_s.presence
    if manual && %w[dnd invisible].include?(manual)
      current_user.update_columns(online_state: User.online_states[manual.to_sym], online_at: Time.current)
      broadcast_state = manual == "invisible" ? "offline" : manual
      broadcast_presence_later(broadcast_state)
      publish_nostr_status(broadcast_state)
    else
      current_user.update_columns(online_state: User.online_states[:online], online_at: Time.current)
      broadcast_presence_later("online")
      publish_nostr_status("online")
    end
  end

  def unsubscribed
    AppearanceOfflineJob.set(wait: 45.seconds).perform_later(current_user.id)
  end

  def ping(data = {})
    if current_user.dnd? || current_user.invisible?
      current_user.update_columns(online_at: Time.current)
    else
      state = data["state"] == "idle" ? :idle : :online
      current_user.update_columns(online_state: User.online_states[state], online_at: Time.current)
    end

    # Republish Nostr presence every ~2 minutes so remote instances
    # can detect staleness if we stop publishing (crash/shutdown).
    last_publish = @_last_nostr_presence_at || 0
    if Time.current.to_f - last_publish > 120
      @_last_nostr_presence_at = Time.current.to_f
      broadcast_state = current_user.invisible? ? "offline" : current_user.online_state
      publish_nostr_status(broadcast_state)
    end
  end

  def away
    return if current_user.dnd? || current_user.invisible?

    current_user.update_columns(online_state: User.online_states[:idle], online_at: Time.current)
    broadcast_presence("idle")
    publish_nostr_status("idle")
  end

  def back
    return if current_user.dnd? || current_user.invisible?

    current_user.update_columns(online_state: User.online_states[:online], online_at: Time.current)
    broadcast_presence("online")
    publish_nostr_status("online")
  end

  def set_status(data)
    status = data["status"].to_s
    return unless %w[online idle dnd invisible].include?(status)

    current_user.update_columns(online_state: User.online_states[status.to_sym], online_at: Time.current)

    # Invisible users appear offline to others
    broadcast_state = status == "invisible" ? "offline" : status
    broadcast_presence(broadcast_state)
    publish_nostr_status(broadcast_state)
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
