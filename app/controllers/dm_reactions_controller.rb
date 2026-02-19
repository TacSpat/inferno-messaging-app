class DmReactionsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation
  before_action :set_message

  def toggle
    emoji = params[:emoji]
    return head :bad_request unless emoji.present?

    existing = @message.reactions.find_by(user: current_user, emoji: emoji)

    if existing
      existing.destroy
    else
      @message.reactions.create!(user: current_user, emoji: emoji)
    end

    html = render_to_string(partial: "messages/reactions", locals: { message: @message.reload, reaction_controller: "dm-message-form" })
    ConversationChannel.broadcast_to(
      @conversation,
      { type: "update_reactions", message_id: @message.public_id, html: html }
    )

    head :ok
  end

  private

  def set_conversation
    @conversation = Conversation.find_by!(public_id: params[:conversation_id])
    unless @conversation.participants.include?(current_user)
      head :forbidden
    end
  end

  def set_message
    @message = @conversation.messages.find_by!(public_id: params[:id])
  end
end
