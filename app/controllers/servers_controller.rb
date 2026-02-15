class ServersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server, only: [:edit, :update, :destroy, :join, :leave]
  before_action :set_no_cache, only: [:new]

  def new
    @server = Server.new
  end

  def create
    @server = Server.new(server_params)
    @server.owner = current_user
    if @server.save
      redirect_to server_channel_path(@server, @server.channels.first), status: :see_other
    else
      render :new, status: :unprocessable_entity
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

  private

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
