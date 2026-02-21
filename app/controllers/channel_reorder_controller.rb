class ChannelReorderController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :authorize_manage!

  # PATCH /servers/:server_id/reorder_channels
  def update
    channels_data = params[:channels] || []
    categories_data = params[:categories] || []

    ActiveRecord::Base.transaction do
      channels_data.each do |ch|
        channel = @server.channels.find_by(public_id: ch[:id])
        next unless channel
        cat = ch[:category_id].present? ? @server.categories.find_by(public_id: ch[:category_id]) : nil
        channel.update_columns(
          position: ch[:position].to_i,
          category_id: cat&.id
        )
      end

      categories_data.each do |cat|
        category = @server.categories.find_by(public_id: cat[:id])
        next unless category
        category.update_columns(position: cat[:position].to_i)
      end
    end

    # Broadcast the new order to all clients
    ServerChannel.broadcast_to(@server, {
      type: "sidebar_reorder",
      channels: channels_data.as_json,
      categories: categories_data.as_json
    })

    publish_server_structure
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
