class ServerChannel < ApplicationCable::Channel
  def subscribed
    @server = Server.find_by!(public_id: params[:server_id])
    stream_for @server
  end

  def unsubscribed
  end
end
