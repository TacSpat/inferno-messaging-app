class AppearanceOfflineJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user

    # Client pings every 30s, so if online_at was updated within 45s
    # the user still has the page open (just lost the WebSocket briefly)
    return if user.online_at && user.online_at > 45.seconds.ago

    user.update_columns(online_state: User.online_states[:offline])

    payload = { type: "presence", user_id: user.public_id, state: "offline" }

    user.servers.each do |server|
      ServerChannel.broadcast_to(server, payload)
    end

    user.conversations.each do |conversation|
      ConversationChannel.broadcast_to(conversation, payload)
    end

    user.friends.select(:id).each do |friend|
      ActionCable.server.broadcast("user_notifications_#{friend.id}", payload)
    end
  end
end
