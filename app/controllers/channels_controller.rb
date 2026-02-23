class ChannelsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_channel, only: [ :show, :edit, :update, :destroy, :older_messages, :newer_messages, :around_messages ]
  before_action :ensure_member!
  before_action :ensure_channel_access!, only: [ :show, :older_messages, :newer_messages, :around_messages ]
  before_action :ensure_manage_channels!, only: [ :new, :create, :edit, :update, :destroy ]

  def show
    # Ensure current user appears online (WebSocket reconnects after page render)
    current_user.update_columns(online_state: User.online_states[:online], online_at: Time.current) if current_user.offline?

    @current_membership = current_user.server_memberships.find_by(server: @server)
    @members = @server.all_members

    if @channel.voice?
      @voice_states = @channel.voice_states.includes(:user)
      @voice_configured = @server.voice_ready?
      render "channels/show_voice"
      return
    end

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

    # Sync remote members from relays in background
    server = @server
    if server.nostr_group_id.present?
      Thread.new { NostrServerSyncService.new(server.nostr_group_id).resync_members }

      # Publish current user's member event with profile data (debounced to once per 10 min)
      @@member_event_published ||= {}
      cache_key = "#{current_user.id}:#{server.id}"
      last_published = @@member_event_published[cache_key]
      if last_published.nil? || last_published < 10.minutes.ago
        @@member_event_published[cache_key] = Time.current
        NostrServerPublishJob.perform_later(current_user.id, server.id, "member", pubkey: current_user.nostr_public_key)
      end
    end
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
        category_id: @channel.category&.public_id,
        channel_type: @channel.channel_type
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
    @channel.assign_attributes(channel_params)
    encryption_changed = @channel.encrypted_changed?
    if @channel.save
      if encryption_changed
        # Encryption state changed — force full sidebar refresh for all members
        # so visibility checks re-run and icons update
        ServerChannel.broadcast_to(@server, { type: "sidebar_refresh" })
      else
        ServerChannel.broadcast_to(@server, {
          type: "channel_updated",
          channel_id: @channel.public_id,
          name: @channel.name,
          category_id: @channel.category&.public_id,
          channel_type: @channel.channel_type
        })
      end
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

  def ensure_channel_access!
    access = @channel.visible_to?(current_user)
    if access == false
      redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have access to this channel."
    elsif access == :read_only
      @read_only_channel = true
    end
  end

  def ensure_manage_channels!
    membership = current_user.server_memberships.find_by(server: @server)
    unless membership&.has_permission?("manage_channels")
      redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission to manage channels."
    end
  end

  def channel_params
    permitted = params.require(:channel).permit(:name, :topic, :channel_type, :nsfw, :category_id, :encrypted, :voice_bitrate, :voice_user_limit, :video_enabled, allowed_role_ids: [])
    if permitted[:encrypted] == "1" || permitted[:encrypted] == true
      role_ids = (permitted.delete(:allowed_role_ids) || []).reject(&:blank?)
      permitted[:permissions_overrides] = { "allowed_role_ids" => role_ids }
    else
      permitted.delete(:allowed_role_ids)
      # Turning off encryption — clear role restrictions
      permitted[:permissions_overrides] = nil if permitted.key?(:encrypted)
    end
    permitted
  end

  def publish_server_structure
    return unless current_user.nostr_public_key.present?
    NostrServerPublishJob.perform_later(current_user.id, @server.id, "structure")
  end
end
