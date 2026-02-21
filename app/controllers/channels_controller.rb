class ChannelsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_channel, only: [ :show, :edit, :update, :destroy, :older_messages, :newer_messages, :around_messages ]
  before_action :ensure_member!

  def show
    # Ensure current user appears online (WebSocket reconnects after page render)
    current_user.update_columns(online_state: User.online_states[:online], online_at: Time.current) if current_user.offline?

    @current_membership = current_user.server_memberships.find_by(server: @server)
    @members = @server.members.includes(server_memberships: :roles, avatar_attachment: :blob)

    @messages = @channel.messages.includes(user: { avatar_attachment: :blob, server_memberships: :roles }, reactions: {}, files_attachments: :blob)
                        .ordered.last(50)
    @has_older = @messages.any? && @channel.messages.where("created_at < ?", @messages.first.created_at).exists?
    @message = Message.new
    current_user.notifications.unread.for_channel(@channel.id).update_all(read: true)
    ChannelRead.upsert(
      { user_id: current_user.id, channel_id: @channel.id, last_read_at: Time.current },
      unique_by: [ :user_id, :channel_id ]
    )

    # Fetch any missed messages from relays in background
    channel = @channel
    Thread.new { NostrHistoryFetcher.fetch_channel(channel) } if channel.nostr_group_id.present?
  end

  def older_messages
    before_message = @channel.messages.find_by(public_id: params[:before])
    return head :bad_request unless before_message

    @messages = @channel.messages
                  .includes(user: { avatar_attachment: :blob, server_memberships: :roles }, reactions: {}, files_attachments: :blob)
                  .where("messages.created_at < ?", before_message.created_at)
                  .ordered.last(50)
    @has_older = @messages.any? && @channel.messages.where("created_at < ?", @messages.first.created_at).exists?

    response.headers["X-Has-Older"] = @has_older.to_s
    render partial: "channels/older_messages", locals: {
      messages: @messages,
      server: @server,
      has_older: @has_older,
      oldest_id: @messages.any? ? @messages.first.public_id : nil
    }
  end

  def newer_messages
    after_message = @channel.messages.find_by(public_id: params[:after])
    return head :bad_request unless after_message

    @messages = @channel.messages
                  .includes(user: { avatar_attachment: :blob, server_memberships: :roles }, reactions: {}, files_attachments: :blob)
                  .where("messages.created_at > ?", after_message.created_at)
                  .ordered.first(50)
    @has_newer = @messages.any? && @channel.messages.where("created_at > ?", @messages.last.created_at).exists?

    response.headers["X-Has-Newer"] = @has_newer.to_s
    render partial: "channels/newer_messages", locals: {
      messages: @messages,
      server: @server,
      has_newer: @has_newer,
      newest_id: @messages.any? ? @messages.last.public_id : nil
    }
  end

  def around_messages
    around_message = @channel.messages.find_by(public_id: params[:around])
    return head :bad_request unless around_message

    includes_list = { user: { avatar_attachment: :blob, server_memberships: :roles }, reactions: {}, files_attachments: :blob }

    before_msgs = @channel.messages.includes(includes_list)
                    .where("messages.created_at <= ?", around_message.created_at)
                    .ordered.last(26)

    after_msgs = @channel.messages.includes(includes_list)
                   .where("messages.created_at > ?", around_message.created_at)
                   .ordered.first(25)

    @messages = before_msgs + after_msgs
    @has_older = @messages.any? && @channel.messages.where("created_at < ?", @messages.first.created_at).exists?
    @has_newer = after_msgs.any? && @channel.messages.where("created_at > ?", @messages.last.created_at).exists?

    response.headers["X-Has-Older"] = @has_older.to_s
    response.headers["X-Has-Newer"] = @has_newer.to_s

    render partial: "channels/around_messages", locals: {
      messages: @messages,
      server: @server
    }
  end

  def new
    category = params[:category_id].present? ? @server.categories.find_by(public_id: params[:category_id]) : nil
    @channel = @server.channels.new(category: category)
  end

  def create
    @channel = @server.channels.new(channel_params)
    if params[:channel] && params[:channel][:category_id].present?
      @channel.category = @server.categories.find_by(public_id: params[:channel].delete(:category_id))
    end
    if @channel.save
      ServerChannel.broadcast_to(@server, {
        type: "channel_created",
        channel_id: @channel.public_id,
        name: @channel.name,
        category_id: @channel.category&.public_id
      })
      publish_server_structure
      redirect_to server_channel_path(@server, @channel)
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if params[:channel] && params[:channel][:category_id].present?
      @channel.category = @server.categories.find_by(public_id: params[:channel].delete(:category_id))
    end
    if @channel.update(channel_params)
      ServerChannel.broadcast_to(@server, {
        type: "channel_updated",
        channel_id: @channel.public_id,
        name: @channel.name,
        category_id: @channel.category&.public_id
      })
      publish_server_structure
      redirect_to server_channel_path(@server, @channel)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    channel_public_id = @channel.public_id
    @channel.destroy
    ServerChannel.broadcast_to(@server, {
      type: "channel_deleted",
      channel_id: channel_public_id
    })
    publish_server_structure
    redirect_to server_channel_path(@server, @server.channels.ordered.first)
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def set_channel
    @channel = @server.channels.find_by!(public_id: params[:id])
  end

  def ensure_member!
    unless current_user.servers.include?(@server)
      redirect_to root_path, alert: "You're not a member of this server."
    end
  end

  def channel_params
    params.require(:channel).permit(:name, :topic, :channel_type, :nsfw, :category_id)
  end

  def publish_server_structure
    return unless current_user.nostr_public_key.present?
    NostrServerPublishJob.perform_later(current_user.id, @server.id, "structure")
  end
end
