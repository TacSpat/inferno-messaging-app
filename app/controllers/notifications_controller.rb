class NotificationsController < ApplicationController
  before_action :authenticate_user!

  # POST /notifications/mark_read
  def mark_read
    scope = current_user.notifications.unread

    if params[:server_id].present?
      server = Server.find_by(public_id: params[:server_id])
      scope = scope.for_server(server.id) if server
    end

    if params[:channel_id].present?
      channel = Channel.find_by(public_id: params[:channel_id])
      scope = scope.for_channel(channel.id) if channel
    end

    scope.update_all(read: true)

    # Also mark channel reads for unread indicators
    if params[:channel_id].present? && channel
      ChannelRead.upsert(
        { user_id: current_user.id, channel_id: channel.id, last_read_at: Time.current },
        unique_by: [:user_id, :channel_id]
      )
    end
    if params[:server_id].present? && server && params[:channel_id].blank?
      server.channels.find_each do |ch|
        ChannelRead.upsert(
          { user_id: current_user.id, channel_id: ch.id, last_read_at: Time.current },
          unique_by: [:user_id, :channel_id]
        )
      end
    end

    head :ok
  end

  # POST /notifications/mark_dm_read
  def mark_dm_read
    if params[:conversation_id].present?
      conversation = Conversation.find_by(public_id: params[:conversation_id])
      cp = conversation ? current_user.conversation_participants.find_by(conversation_id: conversation.id) : nil
      cp&.mark_read!
    else
      current_user.conversation_participants.update_all(last_read_at: Time.current)
    end
    head :ok
  end
end
