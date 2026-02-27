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

    # Ensure contacts exist for all DM counterparties (resolve missing profiles in background)
    dm_pubkeys = @conversations.where.not(counterparty_pubkey: nil).pluck(:counterparty_pubkey)
    if dm_pubkeys.any?
      existing = Contact.where(pubkey: dm_pubkeys).pluck(:pubkey)
      missing = dm_pubkeys - existing
      missing.each { |pk| Thread.new { NostrProfileResolver.resolve(pk) } } if missing.any?
    end

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
    @has_older = @messages.any? && @conversation.messages.where("created_at < ?", @messages.first.created_at).exists?
    @message = Message.new
    @other_user = @conversation.other_user(current_user) if @conversation.direct?
    if @other_user.nil? && @conversation.counterparty_pubkey.present?
      contact_pubkey = @conversation.counterparty_pubkey
      @dm_contact = Contact.find_by(pubkey: contact_pubkey)

      if @dm_contact.nil?
        # First time viewing this DM — create contact and resolve profile
        NostrProfileResolver.resolve(contact_pubkey)
        @dm_contact = Contact.find_by(pubkey: contact_pubkey)
      elsif @dm_contact.profile_stale?
        Thread.new { NostrProfileResolver.resolve(contact_pubkey) }
      end
    end

    # Mark conversation as read
    @conversation.conversation_participants.find_by(user: current_user)&.mark_read!

    # Fetch any missed messages from relays in background
    conv = @conversation
    Thread.new { NostrHistoryFetcher.fetch_conversation(conv) } if conv.counterparty_pubkey.present?
  end

  def create
    if params[:pubkey].present?
      # P2P DM with a contact identified by pubkey
      conversation = Conversation.find_or_create_by_pubkey(current_user, params[:pubkey])
      redirect_to conversation_path(conversation)
    elsif params[:user_id].present?
      target_user = User.find_by!(public_id: params[:user_id])
      if current_user.blocked?(target_user) || target_user.blocked?(current_user)
        redirect_to conversations_path, alert: "Cannot message this user"
        return
      end
      conversation = Conversation.find_or_create_direct(current_user, target_user)
      redirect_to conversation_path(conversation)
    else
      redirect_to conversations_path, alert: "No recipient specified"
    end
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
