class ServerEmojisController < ApplicationController
  before_action :authenticate_user!
  before_action :set_server
  before_action :set_membership
  before_action :ensure_create_emojis!, only: [ :create ]
  before_action :ensure_manage_emojis!, only: [ :destroy ]

  def index
    emojis = @server.server_emojis.includes(image_attachment: :blob).order(:name).map do |emoji|
      {
        id: emoji.public_id,
        name: emoji.name,
        image_url: emoji.image_url,
        creator: emoji.creator.username
      }
    end

    respond_to do |format|
      format.json { render json: { emojis: emojis } }
      format.html { redirect_to server_settings_emojis_path(@server) }
    end
  end

  def create
    emoji = @server.server_emojis.new(emoji_params)
    emoji.creator = current_user

    if emoji.save
      publish_server_emojis
      respond_to do |format|
        format.json { render json: { id: emoji.public_id, name: emoji.name, image_url: emoji.image_url }, status: :created }
        format.html { redirect_to server_settings_emojis_path(@server), notice: "Emoji :#{emoji.name}: uploaded!" }
      end
    else
      respond_to do |format|
        format.json { render json: { errors: emoji.errors.full_messages }, status: :unprocessable_entity }
        format.html { redirect_to server_settings_emojis_path(@server), alert: emoji.errors.full_messages.join(", ") }
      end
    end
  end

  def destroy
    emoji = @server.server_emojis.find_by!(public_id: params[:id])
    name = emoji.name
    emoji.destroy
    publish_server_emojis

    respond_to do |format|
      format.json { head :ok }
      format.html { redirect_to server_settings_emojis_path(@server), notice: "Emoji :#{name}: deleted." }
    end
  end

  private

  def set_server
    @server = Server.find_by!(public_id: params[:server_id])
  end

  def set_membership
    @membership = @server.server_memberships.find_by(user: current_user)
  end

  def ensure_create_emojis!
    unless @membership&.has_permission?("create_emojis") || @membership&.has_permission?("manage_emojis") || @membership&.has_permission?("manage_server") || @membership&.admin?
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

  def emoji_params
    params.require(:server_emoji).permit(:name, :image)
  end

  def publish_server_emojis
    return unless current_user.nostr_public_key.present?
    NostrServerPublishJob.perform_later(current_user.id, @server.id, "emojis")
  end
end
