class ConversationsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation, only: [ :show, :accept, :destroy ]
  before_action :set_dm_layout

  def index
    @tab = params[:tab] || "online"
    @conversations = current_user.conversations
      .includes(participants: { avatar_attachment: :blob }, messages: :user)
      .order(Arel.sql("messages.created_at DESC NULLS LAST"))
      .distinct
    @pending_count = Contact.pending_incoming.count

    case @tab
    when "online"
      @contacts = Contact.friends.select(&:online?)
    when "all"
      @contacts = Contact.friends.order(:display_name)
    when "pending"
      @incoming = Contact.pending_incoming
      @outgoing = Contact.pending_outgoing
    when "blocked"
      @blocked = current_user.blocked_users.includes(avatar_attachment: :blob)
    when "search"
      # Search results are loaded via Stimulus controller (GET /nostr/search?q=)
    end
  end

  def show
    unless @conversation.participants.include?(current_user)
      redirect_to conversations_path, alert: "Not authorized"
      return
    end
    @conversations = current_user.conversations
      .includes(participants: { avatar_attachment: :blob }, messages: :user)
      .order(Arel.sql("messages.created_at DESC NULLS LAST"))
      .distinct
    @messages = @conversation.messages.includes(user: { avatar_attachment: :blob }, reactions: {}, files_attachments: :blob)
                             .order(created_at: :asc).last(50)
    @message = Message.new
    @other_user = @conversation.other_user(current_user) if @conversation.direct?
    # Mark conversation as read
    @conversation.conversation_participants.find_by(user: current_user)&.mark_read!
  end

  def create
    target_user = User.find_by!(public_id: params[:user_id])
    if current_user.blocked?(target_user) || target_user.blocked?(current_user)
      redirect_to conversations_path, alert: "Cannot message this user"
      return
    end
    conversation = Conversation.find_or_create_direct(current_user, target_user)
    redirect_to conversation_path(conversation)
  end

  def accept
    participant = @conversation.conversation_participants.find_by(user: current_user)
    participant&.update!(accepted: true)
    redirect_to conversation_path(@conversation)
  end

  def destroy
    participant = @conversation.conversation_participants.find_by(user: current_user)
    participant&.destroy
    redirect_to conversations_path
  end

  private

  def set_dm_layout
    @dm_layout = true
  end

  def set_conversation
    @conversation = Conversation.find_by!(public_id: params[:id])
  end
end
