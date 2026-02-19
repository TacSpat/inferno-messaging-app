class ConversationsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation, only: [ :show, :accept, :destroy ]
  before_action :set_dm_layout

  def index
    @tab = params[:tab] || "online"
    @conversations = current_user.conversations
      .includes(participants: { avatar_attachment: :blob }, messages: :user)
      .order("messages.created_at DESC NULLS LAST")
      .distinct
    @pending_count = current_user.pending_friend_requests.count

    case @tab
    when "online"
      @friends = current_user.friends.includes(avatar_attachment: :blob).where.not(online_state: :offline).order(:display_name)
      @remote_friends = current_user.remote_friend_references.prefer_https.online.ordered if current_user.remote?
    when "all"
      @friends = current_user.friends.includes(avatar_attachment: :blob).order(:display_name)
      @remote_friends = current_user.remote_friend_references.prefer_https.ordered if current_user.remote?
    when "pending"
      @incoming = current_user.incoming_friend_requests.includes(user: { avatar_attachment: :blob })
      @outgoing = current_user.sent_friend_requests.includes(friend: { avatar_attachment: :blob })
    when "blocked"
      @blocked = current_user.blocked_users.includes(avatar_attachment: :blob)
    end
  end

  def show
    unless @conversation.participants.include?(current_user)
      redirect_to conversations_path, alert: "Not authorized"
      return
    end
    @conversations = current_user.conversations
      .includes(participants: { avatar_attachment: :blob }, messages: :user)
      .order("messages.created_at DESC NULLS LAST")
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
    @remote_conversations = current_user.remote_conversation_references.prefer_https.ordered
  end

  def set_conversation
    @conversation = Conversation.find_by!(public_id: params[:id])
  end
end
