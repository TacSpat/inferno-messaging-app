class ServerFoldersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_folder, only: [ :update, :destroy, :toggle_collapse ]

  def create
    @folder = current_user.server_folders.build(folder_params)

    # Assign the folder a position after existing items
    max_pos = [
      current_user.server_folders.maximum(:position) || -1,
      current_user.server_memberships.maximum(:position) || -1
    ].max
    @folder.position = max_pos + 1

    if @folder.save
      # Move the specified local servers into this folder
      if params[:server_ids].present?
        memberships = current_user.server_memberships.joins(:server)
          .where(servers: { public_id: params[:server_ids] })
        memberships.update_all(server_folder_id: @folder.id)
      end

      # Move the specified remote servers into this folder
      if params[:remote_server_ids].present?
        current_user.remote_server_references
          .where(id: params[:remote_server_ids])
          .update_all(server_folder_id: @folder.id)
      end

      html = render_to_string(
        partial: "shared/server_folder",
        locals: { item: build_folder_item(@folder), active_server: nil }
      )

      render json: { id: @folder.public_id, name: @folder.name, html: html }
    else
      render json: { errors: @folder.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @folder.update(folder_params)
      render json: { id: @folder.public_id, name: @folder.name, color: @folder.color }
    else
      render json: { errors: @folder.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    # Move folder's servers (local + remote) back to top level at the folder's position
    @folder.server_memberships.update_all(server_folder_id: nil, position: @folder.position)
    @folder.remote_server_references.update_all(server_folder_id: nil, position: @folder.position)
    @folder.destroy
    head :ok
  end

  def toggle_collapse
    @folder.update!(collapsed: !@folder.collapsed)
    head :ok
  end

  private

  def set_folder
    @folder = current_user.server_folders.find_by!(public_id: params[:id])
  end

  def folder_params
    params.require(:server_folder).permit(:name, :color)
  end

  def build_folder_item(folder)
    folder.reload
    folder_items = []

    folder.server_memberships.includes(:server).ordered.each do |m|
      folder_items << { type: :server, server: m.server, position: m.position }
    end

    folder.remote_server_references.ordered.each do |r|
      folder_items << { type: :remote_server, remote_ref: r, position: r.position }
    end

    folder_items.sort_by! { |i| i[:position] }
    { type: :folder, folder: folder, items: folder_items, position: folder.position }
  end
end
