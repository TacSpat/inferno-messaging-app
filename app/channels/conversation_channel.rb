class ConversationChannel < ApplicationCable::Channel
  def subscribed
    @conversation = Conversation.find_by!(public_id: params[:conversation_id])
    if @conversation.participants.include?(current_user)
      stream_for @conversation
      send_presence_sync
    else
      reject
    end
  end

  def unsubscribed
  end

  def typing(data)
    ConversationChannel.broadcast_to(
      @conversation,
      {
        type: "typing",
        user_id: current_user.public_id,
        username: current_user.display_name.presence || current_user.username
      }
    )
  end

  private

  def send_presence_sync
    other_participants = @conversation.participants.where.not(id: current_user.id)
                                     .select(:public_id, :online_state)
    other_participants.each do |user|
      transmit({ type: "presence", user_id: user.public_id, state: user.online_state })
    end
  end
end
