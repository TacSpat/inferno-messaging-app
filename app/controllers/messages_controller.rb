class MessagesController < ApplicationController
  include FileTypeValidatable

  before_action :authenticate_user!
  before_action :set_channel
  before_action :set_message, only: [ :edit, :update, :destroy ]
  before_action :validate_file_types, only: [ :create, :update ]

  def create
    @message = @channel.messages.new(message_params.except(:parent_id))
    @message.user = current_user
    if params[:message][:parent_id].present?
      @message.parent = @channel.messages.find_by(public_id: params[:message][:parent_id])
    end

    if @message.save
      # Preload associations for rendering to avoid N+1
      ActiveRecord::Associations::Preloader.new(records: [ @message.user ], associations: { server_memberships: :roles }).call
      # Publish as NIP-29 Kind 9 event to relays (in background)
      if @channel.nostr_group_id.present? && current_user.nostr_public_key.present?
        msg = @message
        channel = @channel
        Thread.new { publish_channel_message_to_nostr(msg, channel) }
      end

      # Broadcast via ActionCable
      ChannelChatChannel.broadcast_to(
        @channel,
        {
          type: "new_message",
          html: render_to_string(partial: "messages/message", locals: { message: @message, server: @channel.server })
        }
      )
      # Broadcast unread indicator to server members (except author)
      @channel.server.members.where.not(id: current_user.id).find_each do |member|
        ActionCable.server.broadcast("user_notifications_#{member.id}", {
          type: "channel_message",
          server_id: @channel.server.public_id,
          channel_id: @channel.public_id,
          user_id: current_user.public_id
        })
      end

      respond_to do |format|
        format.turbo_stream { head :ok }
        format.html { redirect_to server_channel_path(@channel.server, @channel) }
      end
    else
      respond_to do |format|
        format.turbo_stream { head :unprocessable_entity }
        format.html { redirect_to server_channel_path(@channel.server, @channel), alert: @message.errors.full_messages.join(", ") }
      end
    end
  end

  def edit
  end

  def update
    @message.edited_at = Time.current
    # Remove specific file attachments if requested
    if params[:message][:remove_file_ids].present?
      params[:message][:remove_file_ids].each do |file_id|
        attachment = @message.files.find { |f| f.id.to_s == file_id.to_s }
        attachment&.purge
      end
    end
    if @message.update(message_params)
      # Preload associations for rendering to avoid N+1
      ActiveRecord::Associations::Preloader.new(records: [ @message.user ], associations: { server_memberships: :roles }).call
      ChannelChatChannel.broadcast_to(
        @channel,
        {
          type: "update_message",
          message_id: @message.public_id,
          html: render_to_string(partial: "messages/message", locals: { message: @message, server: @channel.server })
        }
      )
      # Publish edit to Nostr as new Kind 9 event with edit tag
      if @channel.nostr_group_id.present? && current_user.nostr_public_key.present? && @message.nostr_event_id.present?
        msg = @message
        channel = @channel
        Thread.new { publish_channel_edit_to_nostr(msg, channel) }
      end
      head :ok
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    message_public_id = @message.public_id

    # Publish NIP-29 delete event to relays
    event_log = NostrEventLog.find_by(message: @message)
    if event_log
      NostrGroupModerationJob.perform_later(
        :delete_event,
        channel_id: @channel.id,
        moderator_id: current_user.id,
        target_event_id: event_log.event_id
      )
    end

    @message.destroy
    ChannelChatChannel.broadcast_to(
      @channel,
      { type: "delete_message", message_id: message_public_id }
    )
    head :ok
  end

  private

  def set_channel
    @channel = Channel.find_by!(public_id: params[:channel_id])
  end

  def set_message
    @message = @channel.messages.find_by!(public_id: params[:id])
  end

  def message_params
    permitted = params.require(:message).permit(:content, :parent_id, files: [])
    permitted[:files] = permitted[:files].reject(&:blank?) if permitted[:files].is_a?(Array)
    permitted
  end

  def publish_channel_edit_to_nostr(message, channel)
    user = message.user

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 9,
      pubkey: user.nostr_public_key,
      content: message.content || "",
      tags: [
        ["h", channel.nostr_group_id],
        ["e", message.nostr_event_id, "", "edit"]
      ]
    )
    signed = signer.sign(event)
    RelayService.publish_to_all(signed.to_json)
  rescue => e
    Rails.logger.error("Failed to publish channel edit to Nostr: #{e.message}")
  end

  def publish_channel_message_to_nostr(message, channel)
    user = message.user

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 9, # NIP-29 group chat message
      pubkey: user.nostr_public_key,
      content: message.content || "",
      tags: [
        ["h", channel.nostr_group_id]
      ]
    )
    signed = signer.sign(event)
    signed_hash = signed.to_json  # Returns a Hash (gem override)

    message.update_columns(nostr_event_id: signed.id)

    NostrEventLog.create!(
      event_id: signed.id,
      kind: 9,
      pubkey: user.nostr_public_key,
      message: message,
      channel: channel,
      direction: "outbound",
      event_created_at: Time.current
    )

    RelayService.publish_to_all(signed_hash)
  rescue => e
    Rails.logger.error("Failed to publish channel message to Nostr: #{e.message}")
  end
end
