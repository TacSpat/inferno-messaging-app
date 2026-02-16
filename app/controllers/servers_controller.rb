class ServersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server, only: [:edit, :update, :destroy, :join, :leave]
  before_action :set_no_cache, only: [:new]

  def new
    @server = Server.new
  end

  def create
    if params[:instance_url].present? && params[:instance_url] != "local"
      create_remote_server
    else
      create_local_server
    end
  end

  def edit
    authorize @server
  end

  def update
    authorize @server
    if @server.update(server_params)
      redirect_to server_channel_path(@server, @server.channels.ordered.first)
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    authorize @server
    @server.destroy
    redirect_to root_path, notice: "Server deleted.", status: :see_other
  end

  def join
    unless current_user.servers.include?(@server)
      @server.server_memberships.create!(user: current_user)
    end
    redirect_to server_channel_path(@server, @server.channels.ordered.first)
  end

  def leave
    membership = @server.server_memberships.find_by(user: current_user)
    if membership && @server.owner != current_user
      membership.destroy
      redirect_to root_path, notice: "Left server.", status: :see_other
    else
      redirect_back fallback_location: root_path, alert: "Can't leave a server you own."
    end
  end

  def reorder_servers
    items = params.require(:items)
    memberships = current_user.server_memberships.includes(:server).index_by { |m| m.server.public_id }
    folders = current_user.server_folders.index_by(&:public_id)

    ActiveRecord::Base.transaction do
      items.each do |entry|
        pos = entry[:position].to_i
        if entry[:type] == "folder"
          folder = folders[entry[:id]]
          next unless folder
          folder.update_column(:position, pos)

          # Update servers inside this folder
          (entry[:servers] || []).each do |server_entry|
            membership = memberships[server_entry[:id]]
            next unless membership
            membership.update_columns(position: server_entry[:position].to_i, server_folder_id: folder.id)
          end
        else
          membership = memberships[entry[:id]]
          next unless membership
          membership.update_columns(position: pos, server_folder_id: nil)
        end
      end
    end

    head :ok
  end

  private

  def create_local_server
    @server = Server.new(server_params)
    @server.owner = current_user
    if @server.save
      redirect_to server_channel_path(@server, @server.channels.first), status: :see_other
    else
      render :new, status: :unprocessable_entity
    end
  end

  def create_remote_server
    ref = FederationService.create_remote_server(
      user: current_user,
      instance_url: params[:instance_url],
      name: params[:server][:name],
      description: params[:server][:description]
    )
    redirect_to root_path, notice: "Server \"#{ref.name}\" created on #{ref.instance_domain}!"
  rescue FederationService::FederationError => e
    @server = Server.new(server_params)
    flash.now[:alert] = "Failed to create remote server: #{e.message}"
    render :new, status: :unprocessable_entity
  end

  def set_server
    @server = Server.find_by!(public_id: params[:id])
  end

  def server_params
    params.require(:server).permit(:name, :description, :icon)
  end

  def set_no_cache
    response.headers["Cache-Control"] = "no-cache, no-store, must-revalidate"
    response.headers["Pragma"] = "no-cache"
    response.headers["Expires"] = "0"
  end
end
