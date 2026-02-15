class ConversationChannel < ApplicationCable::Channel
  def subscribed
    @conversation = Conversation.find_by!(public_id: params[:conversation_id])
    if @conversation.participants.include?(current_user)
      stream_for @conversation
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
end
