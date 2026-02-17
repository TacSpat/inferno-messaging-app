class DmMessagesController < ApplicationController
  include FileTypeValidatable

  before_action :authenticate_user!
  before_action :set_conversation
  before_action :set_message, only: [ :update, :destroy ]
  before_action :validate_file_types, only: [ :create, :update ]

  def create
    participant = @conversation.conversation_participants.find_by(user: current_user)
    unless participant
      head :forbidden
      return
    end

    @message = @conversation.messages.new(message_params.except(:parent_id))
    @message.user = current_user
    @message.channel = nil
    if params[:message][:parent_id].present?
      @message.parent = @conversation.messages.find_by(public_id: params[:message][:parent_id])
    end

    if @message.save
      @conversation.conversation_participants.update_all(accepted: true)
      # Update sender's last_read_at
      participant.mark_read!
      ConversationChannel.broadcast_to(
        @conversation,
        {
          type: "new_message",
          html: render_to_string(partial: "messages/dm_message", locals: { message: @message })
        }
      )
      # Notify other participants
      @conversation.participants.where.not(id: current_user.id).each do |recipient|
        ActionCable.server.broadcast("user_notifications_#{recipient.id}", {
          type: "dm_message",
          conversation_id: @conversation.public_id,
          sender_name: current_user.display_name.presence || current_user.username,
          sender_id: current_user.public_id
        })
      end
      respond_to do |format|
        format.turbo_stream { head :ok }
        format.html { redirect_to conversation_path(@conversation) }
      end
    else
      respond_to do |format|
        format.turbo_stream { head :unprocessable_entity }
        format.html { redirect_to conversation_path(@conversation), alert: @message.errors.full_messages.join(", ") }
      end
    end
  end

  def update
    unless @message.user == current_user
      head :forbidden
      return
    end
    @message.edited_at = Time.current
    if params[:message][:remove_file_ids].present?
      params[:message][:remove_file_ids].each do |file_id|
        attachment = @message.files.find { |f| f.id.to_s == file_id.to_s }
        attachment&.purge
      end
    end
    if @message.update(message_params)
      ConversationChannel.broadcast_to(
        @conversation,
        {
          type: "update_message",
          message_id: @message.public_id,
          html: render_to_string(partial: "messages/dm_message", locals: { message: @message })
        }
      )
      respond_to do |format|
        format.turbo_stream { head :ok }
        format.html { redirect_to conversation_path(@conversation) }
      end
    else
      respond_to do |format|
        format.turbo_stream { head :unprocessable_entity }
        format.html { redirect_to conversation_path(@conversation) }
      end
    end
  end

  def destroy
    unless @message.user == current_user
      head :forbidden
      return
    end
    message_public_id = @message.public_id
    @message.destroy
    ConversationChannel.broadcast_to(
      @conversation,
      { type: "delete_message", message_id: message_public_id }
    )
    respond_to do |format|
      format.turbo_stream { head :ok }
      format.html { redirect_to conversation_path(@conversation) }
    end
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

  def message_params
    permitted = params.require(:message).permit(:content, :parent_id, files: [])
    permitted[:files] = permitted[:files].reject(&:blank?) if permitted[:files].is_a?(Array)
    permitted
  end
end
