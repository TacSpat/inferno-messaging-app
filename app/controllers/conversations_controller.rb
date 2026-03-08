class ConversationsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation, only: [ :show, :accept, :update, :destroy, :add_member, :remove_member ]
  before_action :set_dm_layout

  def index
    @tab = params[:tab] || "online"
    @conversations = current_user.conversations
      .includes(conversation_participants: [:user, :contact], participants: { avatar_attachment: :blob }, messages: :user)
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
      @blocked_contacts = Contact.blocked_contacts.order(:display_name)
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
      .includes(conversation_participants: [:user, :contact], participants: { avatar_attachment: :blob }, messages: :user)
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
      if current_user.blocked_pubkey?(params[:pubkey])
        redirect_to conversations_path, alert: "Cannot message this user"
        return
      end
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
    elsif params[:group_chat].present?
      # Group chat creation
      conversation = Conversation.create!(kind: :group_chat, name: params[:group_chat][:name].presence)
      conversation.conversation_participants.create!(user: current_user, accepted: true)
      member_ids = Array(params[:group_chat][:member_ids]).reject(&:blank?)
      member_ids.each do |member_id|
        if member_id.start_with?("contact:")
          contact = Contact.find_by(id: member_id.delete_prefix("contact:"))
          next unless contact
          conversation.conversation_participants.create!(contact: contact, accepted: true)
        else
          uid = member_id.delete_prefix("user:")
          user = User.find_by(public_id: uid)
          next unless user
          conversation.conversation_participants.create!(user: user, accepted: true)
        end
      end
      redirect_to conversation_path(conversation)
    else
      redirect_to conversations_path, alert: "No recipient specified"
    end
  end

  def update
    unless @conversation.participants.include?(current_user)
      head :forbidden
      return
    end
    if @conversation.update(conversation_params)
      # Upload icon to Blossom in background if changed
      if conversation_params[:icon].present?
        conv = @conversation
        Thread.new { BlossomClientService.upload_attachment(conv.icon) }
      end
      redirect_to conversation_path(@conversation)
    else
      redirect_to conversation_path(@conversation), alert: @conversation.errors.full_messages.join(", ")
    end
  end

  def accept
    participant = @conversation.conversation_participants.find_by(user: current_user)
    participant&.update!(accepted: true)
    redirect_to conversation_path(@conversation)
  end

  def add_member
    unless @conversation.group_chat? && @conversation.participants.include?(current_user)
      head :forbidden
      return
    end
    mid = params[:member_id].to_s
    if mid.start_with?("contact:")
      contact = Contact.find_by(id: mid.delete_prefix("contact:"))
      @conversation.conversation_participants.find_or_create_by!(contact: contact) { |cp| cp.accepted = true } if contact
    else
      uid = mid.delete_prefix("user:")
      user = User.find_by(public_id: uid)
      @conversation.conversation_participants.find_or_create_by!(user: user) { |cp| cp.accepted = true } if user
    end
    redirect_to conversation_path(@conversation)
  end

  def remove_member
    unless @conversation.group_chat? && @conversation.participants.include?(current_user)
      head :forbidden
      return
    end
    if params[:contact_id].present?
      @conversation.conversation_participants.find_by(contact_id: params[:contact_id])&.destroy
    elsif params[:member_id].present?
      user = User.find_by!(public_id: params[:member_id])
      @conversation.conversation_participants.find_by(user: user)&.destroy
      if user == current_user
        redirect_to conversations_path and return
      end
    end
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

  def conversation_params
    params.require(:conversation).permit(:name, :icon)
  end
end
