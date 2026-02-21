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
end
