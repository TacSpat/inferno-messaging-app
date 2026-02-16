class Api::GifCollectionsController < ApplicationController
  before_action :authenticate_user!

  def index
    collections = current_user.gif_collections.ordered.map do |c|
      {
        id: c.public_id,
        name: c.name,
        icon: c.icon,
        position: c.position,
        favorites_count: c.gif_favorites.count
      }
    end

    render json: { collections: collections }
  end

  def create
    collection = current_user.gif_collections.new(collection_params)

    if collection.save
      render json: { id: collection.public_id, name: collection.name, icon: collection.icon }, status: :created
    else
      render json: { errors: collection.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    collection = current_user.gif_collections.find_by!(public_id: params[:id])

    if collection.update(collection_params)
      render json: { id: collection.public_id, name: collection.name, icon: collection.icon, position: collection.position }
    else
      render json: { errors: collection.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    collection = current_user.gif_collections.find_by!(public_id: params[:id])
    default = GifCollection.default_for(current_user)

    if collection == default
      return render json: { error: "Cannot delete the default Favorites collection" }, status: :unprocessable_entity
    end

    # Delete favorites that already exist in the default collection, then move the rest
    existing_tenor_ids = default.gif_favorites.pluck(:tenor_gif_id)
    collection.gif_favorites.where(tenor_gif_id: existing_tenor_ids).delete_all
    collection.gif_favorites.update_all(gif_collection_id: default.id)
    collection.destroy

    head :ok
  end

  private

  def collection_params
    params.require(:gif_collection).permit(:name, :position, :icon)
  end
end
