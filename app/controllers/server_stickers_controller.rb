class ServerStickersController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_membership
  before_action :ensure_create_stickers!, only: [:create]
  before_action :ensure_manage_emojis!, only: [:destroy]

  def index
    stickers = @server.server_stickers.includes(image_attachment: :blob).order(:name).map do |sticker|
      {
        id: sticker.public_id,
        name: sticker.name,
        description: sticker.description,
        image_url: sticker.image_url,
        creator: sticker.creator.username
      }
    end

    respond_to do |format|
      format.json { render json: { stickers: stickers } }
      format.html { redirect_to server_settings_stickers_path(@server) }
    end
  end

  def create
    sticker = @server.server_stickers.new(sticker_params)
    sticker.creator = current_user

    if sticker.save
      respond_to do |format|
        format.json { render json: { id: sticker.public_id, name: sticker.name, image_url: sticker.image_url }, status: :created }
        format.html { redirect_to server_settings_stickers_path(@server), notice: "Sticker '#{sticker.name}' uploaded!" }
      end
    else
      respond_to do |format|
        format.json { render json: { errors: sticker.errors.full_messages }, status: :unprocessable_entity }
        format.html { redirect_to server_settings_stickers_path(@server), alert: sticker.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    sticker = @server.server_stickers.find_by!(public_id: params[:id])
    name = sticker.name
    sticker.destroy

    respond_to do |format|
      format.json { head :ok }
      format.html { redirect_to server_settings_stickers_path(@server), notice: "Sticker '#{name}' deleted." }
    end
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def set_membership
    @membership = @server.server_memberships.find_by(user: current_user)
  end

  def ensure_create_stickers!
    unless @membership&.has_permission?("create_stickers") || @membership&.has_permission?("manage_emojis") || @membership&.has_permission?("manage_server") || @membership&.admin?
      respond_to do |format|
        format.json { render json: { error: "Permission denied" }, status: :forbidden }
        format.html { redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission." }
      end
    end
  end

  def ensure_manage_emojis!
    unless @membership&.has_permission?("manage_emojis") || @membership&.has_permission?("manage_server") || @membership&.admin?
      respond_to do |format|
        format.json { render json: { error: "Permission denied" }, status: :forbidden }
        format.html { redirect_to server_channel_path(@server, @server.channels.ordered.first), alert: "You don't have permission." }
      end
    end
  end

  def sticker_params
    params.require(:server_sticker).permit(:name, :description, :image)
  end
end
