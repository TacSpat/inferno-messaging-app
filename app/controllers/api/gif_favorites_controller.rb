class Api::GifFavoritesController < ApplicationController
  before_action :authenticate_user!

  def index
    favorites = current_user.gif_favorites.ordered
    if params[:collection_id].present?
      favorites = favorites.where(gif_collection_id: find_collection.id)
    elsif params[:default].present?
      favorites = favorites.where(gif_collection: GifCollection.default_for(current_user))
    end
    favorites = favorites.where("description ILIKE ?", "%#{params[:q]}%") if params[:q].present?

    render json: {
      favorites: favorites.map { |f| favorite_json(f) }
    }
  end

  def create
    collection = if params[:gif_favorite][:collection_id].present?
      current_user.gif_collections.find_by!(public_id: params[:gif_favorite][:collection_id])
    else
      GifCollection.default_for(current_user)
    end

    favorite = current_user.gif_favorites.new(favorite_params.merge(gif_collection: collection))

    if favorite.save
      render json: favorite_json(favorite), status: :created
    else
      render json: { errors: favorite.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    favorite = current_user.gif_favorites.find_by!(public_id: params[:id])
    collection = current_user.gif_collections.find_by!(public_id: params[:gif_favorite][:collection_id])

    if favorite.update(gif_collection: collection)
      render json: favorite_json(favorite)
    else
      render json: { errors: favorite.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    favorite = current_user.gif_favorites.find_by!(public_id: params[:id])
    favorite.destroy
    head :ok
  end

  def toggle
    default_collection = GifCollection.default_for(current_user)
    existing = current_user.gif_favorites.find_by(tenor_gif_id: params[:tenor_gif_id], gif_collection: default_collection)

    if existing
      existing.destroy
      render json: { favorited: false }
    else
      collection = GifCollection.default_for(current_user)
      favorite = current_user.gif_favorites.create!(
        gif_collection: collection,
        tenor_gif_id: params[:tenor_gif_id],
        tenor_url: params[:tenor_url],
        preview_url: params[:preview_url],
        gif_url: params[:gif_url],
        description: params[:description]
      )
      render json: { favorited: true, id: favorite.public_id }
    end
  rescue ActiveRecord::RecordInvalid => e
    render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
  end

  private

  def find_collection
    current_user.gif_collections.find_by!(public_id: params[:collection_id])
  end

  def favorite_params
    params.require(:gif_favorite).permit(:tenor_gif_id, :tenor_url, :preview_url, :gif_url, :description, :position)
  end

  def favorite_json(f)
    {
      id: f.public_id,
      tenor_gif_id: f.tenor_gif_id,
      tenor_url: f.tenor_url,
      preview_url: f.preview_url,
      gif_url: f.gif_url,
      description: f.description,
      collection_id: f.gif_collection.public_id
    }
  end
end
