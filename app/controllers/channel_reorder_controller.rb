class ChannelReorderController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :authorize_manage!

  # PATCH /servers/:server_id/reorder_channels
  def update
    channels_data = params[:channels] || []
    categories_data = params[:categories] || []

    hierarchy_changed = false

    ActiveRecord::Base.transaction do
      channels_data.each do |ch|
        channel = @server.channels.find_by(public_id: ch[:id])
        next unless channel
        cat = ch[:category_id].present? ? @server.categories.find_by(public_id: ch[:category_id]) : nil

        # Resolve parent_channel_id (voice hierarchy)
        new_parent_id = if ch[:parent_channel_id].present?
          parent = @server.channels.voice.find_by(public_id: ch[:parent_channel_id])
          parent&.id
        end

        old_parent_id = channel.parent_channel_id
        hierarchy_changed = true if old_parent_id != new_parent_id

        channel.update_columns(
          position: ch[:position].to_i,
          category_id: cat&.id,
          parent_channel_id: new_parent_id
        )
      end

      categories_data.each do |cat|
        category = @server.categories.find_by(public_id: cat[:id])
        next unless category
        category.update_columns(position: cat[:position].to_i)
      end
    end

    # If hierarchy changed, do a full sidebar refresh so clients re-render nesting
    if hierarchy_changed
      ServerChannel.broadcast_to(@server, { type: "sidebar_refresh" })
    else
      ServerChannel.broadcast_to(@server, {
        type: "sidebar_reorder",
        channels: channels_data.as_json,
        categories: categories_data.as_json
      })
    end

    publish_server_structure

    # Immediately notify remote instances so their sidebars update in real-time
    if User.owner&.nostr_public_key.present?
      NostrChannelReorderSyncJob.perform_later(
        @server.id,
        channels_data.as_json,
        categories_data.as_json,
        hierarchy_changed
      )
    end

    head :ok
  end

  # DELETE /servers/:server_id/channels/:id/quick_delete
  def destroy_channel
    channel = @server.channels.find_by!(public_id: params[:id])
    if @server.channels.count <= 1
      head :unprocessable_entity
      return
    end
    channel_public_id = channel.public_id
    channel.destroy
    ServerChannel.broadcast_to(@server, { type: "channel_deleted", channel_id: channel_public_id })
    publish_server_structure
    head :ok
  end

  # DELETE /servers/:server_id/categories/:id/quick_delete
  def destroy_category
    category = @server.categories.find_by!(public_id: params[:id])
    category_public_id = category.public_id
    category.channels.update_all(category_id: nil)
    category.destroy
    ServerChannel.broadcast_to(@server, { type: "category_deleted", category_id: category_public_id })
    publish_server_structure
    head :ok
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def authorize_manage!
    membership = current_user.server_memberships.find_by(server: @server)
    unless membership&.has_permission?("manage_channels")
      head :forbidden
    end
  end

  def publish_server_structure
    return unless current_user.nostr_public_key.present?
    NostrServerPublishJob.perform_later(current_user.id, @server.id, "structure")
  end
end
