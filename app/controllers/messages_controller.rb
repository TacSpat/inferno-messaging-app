class MessagesController < ApplicationController
  include FileTypeValidatable

  before_action :authenticate_user!
  before_action :set_channel
  before_action :set_message, only: [ :edit, :update, :destroy ]
  before_action :validate_file_types, only: [ :create, :update ]

  def create
    # Block message creation in encrypted channels where user only has read_only access
    if @channel.encrypted? && @channel.visible_to?(current_user) != :full
      head :forbidden
      return
    end

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
    # Authorize: author can delete own messages, admins/manage_messages can delete any
    unless @message.user == current_user
      membership = current_user.server_memberships.find_by(server: @channel.server)
      unless membership&.has_permission?("manage_messages")
        head :forbidden
        return
      end
    end

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

    # Ensure the Nostr event is logged so the history fetcher doesn't re-import it.
    # Message#destroy nullifies the log's message_id but keeps the event_id entry,
    # which makes NostrEventLog.already_processed? return true. If no log exists
    # (e.g. Thread.new publish failed silently), create one now.
    if @message.nostr_event_id.present? && !NostrEventLog.exists?(event_id: @message.nostr_event_id)
      NostrEventLog.create(
        event_id: @message.nostr_event_id,
        kind: 9,
        pubkey: @message.nostr_author_pubkey || @message.user&.nostr_public_key || "unknown",
        channel: @channel,
        message: @message,
        direction: "inbound",
        event_created_at: @message.created_at
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
    event_content = message.content || ""
    tags = [
      [ "h", channel.nostr_group_id ],
      [ "e", message.nostr_event_id, "", "edit" ]
    ]

    if channel.encrypted? && channel.channel_public_key.present?
      conversation_key = Nip44Service.conversation_key(user.nostr_private_key, channel.channel_public_key)
      event_content = Nip44Service.encrypt(event_content, conversation_key)
      tags << [ "encrypted", "nip44" ]
      tags << [ "channel_pubkey", channel.channel_public_key ]
    end

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 9,
      pubkey: user.nostr_public_key,
      content: event_content,
      tags: tags
    )
    signed = signer.sign(event)
    RelayService.publish_to_all(signed.to_json)
  rescue => e
    Rails.logger.error("Failed to publish channel edit to Nostr: #{e.message}")
  end

  def publish_channel_message_to_nostr(message, channel)
    user = message.user
    event_content = resolve_active_storage_urls(message.content || "")
    tags = [ [ "h", channel.nostr_group_id ] ]

    if channel.encrypted? && channel.channel_public_key.present?
      conversation_key = Nip44Service.conversation_key(user.nostr_private_key, channel.channel_public_key)
      event_content = Nip44Service.encrypt(event_content, conversation_key)
      tags << [ "encrypted", "nip44" ]
      tags << [ "channel_pubkey", channel.channel_public_key ]
    end

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 9, # NIP-29 group chat message
      pubkey: user.nostr_public_key,
      content: event_content,
      tags: tags
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

  # Replace local Active Storage paths with Blossom URLs so remote instances can access them.
  def resolve_active_storage_urls(content)
    content.gsub(%r{/rails/active_storage/blobs/(?:redirect/)?([^/\s]+)/[^\s]+}) do |match|
      signed_id = $1
      blob = ActiveStorage::Blob.find_signed(signed_id)
      next match unless blob

      # Return cached Blossom URL if already uploaded
      cached = blob.metadata&.dig("blossom_url")
      next cached if cached.present?

      # Upload to Blossom and cache the URL
      data = blob.download
      result = BlossomClientService.upload(StringIO.new(data), content_type: blob.content_type || "application/octet-stream", filename: blob.filename.to_s)
      blob.update!(metadata: (blob.metadata || {}).merge("blossom_url" => result[:url], "sha256" => result[:sha256]))
      result[:url]
    rescue => e
      Rails.logger.warn("[MessagesController] Failed to resolve Active Storage URL to Blossom: #{e.message}")
      match
    end
  end
end
