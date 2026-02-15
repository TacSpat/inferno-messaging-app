class AppearanceOfflineJob < ApplicationJob
  queue_as :default

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user

    # Check if they reconnected since this job was enqueued
    # If online_at was updated recently (within last 10s), skip
    return if user.online_at && user.online_at > 5.seconds.ago

    user.update_columns(online_state: User.online_states[:offline])

    user.servers.each do |server|
      ServerChannel.broadcast_to(server, {
        type: "presence",
        user_id: user.id,
        state: "offline"
      })
    end
  end
end
