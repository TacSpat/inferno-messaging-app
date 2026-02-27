class ServerChannel < ApplicationCable::Channel
  def subscribed
    @server = Server.find_by!(public_id: params[:server_id])
    stream_for @server
    send_presence_sync
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
end
