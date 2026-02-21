class CategoriesController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_category, only: [ :edit, :update, :destroy ]
  before_action :authorize_manage!

  def new
    @category = @server.categories.new
  end

  def create
    @category = @server.categories.new(category_params)
    @category.position ||= @server.categories.maximum(:position).to_i + 1

    if @category.save
      ServerChannel.broadcast_to(@server, {
        type: "category_created",
        category_id: @category.public_id,
        name: @category.name
      })
      publish_server_structure
      redirect_to server_channel_path(@server, @server.channels.first), notice: "Category created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @category.update(category_params)
      ServerChannel.broadcast_to(@server, {
        type: "category_updated",
        category_id: @category.public_id,
        name: @category.name
      })
      publish_server_structure
      redirect_to server_channel_path(@server, @server.channels.first), notice: "Category updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    category_public_id = @category.public_id
    @category.channels.update_all(category_id: nil)
    @category.destroy
    ServerChannel.broadcast_to(@server, {
      type: "category_deleted",
      category_id: category_public_id
    })
    publish_server_structure
    redirect_to server_channel_path(@server, @server.channels.first), notice: "Category deleted."
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def set_category
    @category = @server.categories.find_by!(public_id: params[:id])
  end

  def category_params
    params.require(:category).permit(:name, :position)
  end

  def authorize_manage!
    membership = current_user.server_memberships.find_by(server: @server)
    unless membership&.has_permission?("manage_channels")
      redirect_to server_channel_path(@server, @server.channels.first), alert: "Not authorized."
    end
  end

  def publish_server_structure
    return unless current_user.nostr_public_key.present?
    NostrServerPublishJob.perform_later(current_user.id, @server.id, "structure")
  end
end
