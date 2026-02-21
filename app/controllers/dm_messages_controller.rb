class DmMessagesController < ApplicationController
  include FileTypeValidatable

  before_action :authenticate_user!
  before_action :set_conversation
  before_action :set_message, only: [:update, :destroy]
  before_action :validate_file_types, only: [:create, :update]

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
      participant.mark_read!

      # Publish as NIP-44 encrypted Kind 14 event (in background, don't block response)
      if current_user.nostr_public_key.present? && @conversation.counterparty_pubkey.present?
        msg = @message
        conv = @conversation
        Thread.new { publish_dm_to_nostr(msg, conv) }
      end

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
      # Publish edit to Nostr
      if current_user.nostr_public_key.present? && @conversation.counterparty_pubkey.present? && @message.nostr_event_id.present?
        msg = @message
        conv = @conversation
        Thread.new { publish_dm_action_to_nostr(msg, conv, "message_edit") }
      end
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
    nostr_event_id = @message.nostr_event_id
    # Publish delete to Nostr before destroying locally
    if current_user.nostr_public_key.present? && @conversation.counterparty_pubkey.present? && nostr_event_id.present?
      conv = @conversation
      user = current_user
      Thread.new { publish_dm_delete_to_nostr(user, conv, nostr_event_id) }
    end
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

  def publish_dm_to_nostr(message, conversation)
    user = message.user
    counterparty_pubkey = conversation.counterparty_pubkey

    # Build NIP-44 encrypted Kind 14 event
    conversation_key = Nip44Service.conversation_key(user.nostr_private_key, counterparty_pubkey)
    encrypted_content = Nip44Service.encrypt(message.content || "", conversation_key)

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 14,
      pubkey: user.nostr_public_key,
      content: encrypted_content,
      tags: [
        ["p", counterparty_pubkey]
      ]
    )
    signed = signer.sign(event)
    signed_hash = signed.to_json  # Returns a Hash (gem override)

    message.update_columns(
      nostr_event_id: signed.id,
      nostr_event_json: JSON.generate(signed_hash)
    )

    # Publish to all active relays
    RelayService.publish_to_all(signed_hash)
  rescue => e
    Rails.logger.error("Failed to publish DM as Nostr event: #{e.message}")
  end

  def publish_dm_action_to_nostr(message, conversation, action_type)
    user = message.user
    counterparty_pubkey = conversation.counterparty_pubkey

    payload = { type: action_type, event_id: message.nostr_event_id, content: message.content }.to_json
    conversation_key = Nip44Service.conversation_key(user.nostr_private_key, counterparty_pubkey)
    encrypted_content = Nip44Service.encrypt(payload, conversation_key)

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 14,
      pubkey: user.nostr_public_key,
      content: encrypted_content,
      tags: [["p", counterparty_pubkey]]
    )
    signed = signer.sign(event)
    RelayService.publish_to_all(signed.to_json)
  rescue => e
    Rails.logger.error("Failed to publish DM #{action_type} to Nostr: #{e.message}")
  end

  def publish_dm_delete_to_nostr(user, conversation, nostr_event_id)
    counterparty_pubkey = conversation.counterparty_pubkey

    payload = { type: "message_delete", event_id: nostr_event_id }.to_json
    conversation_key = Nip44Service.conversation_key(user.nostr_private_key, counterparty_pubkey)
    encrypted_content = Nip44Service.encrypt(payload, conversation_key)

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 14,
      pubkey: user.nostr_public_key,
      content: encrypted_content,
      tags: [["p", counterparty_pubkey]]
    )
    signed = signer.sign(event)
    RelayService.publish_to_all(signed.to_json)
  rescue => e
    Rails.logger.error("Failed to publish DM delete to Nostr: #{e.message}")
  end
end
