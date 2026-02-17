class ChangeGifFavoritesUniquenessToPerCollection < ActiveRecord::Migration[8.0]
  def change
    remove_index :gif_favorites, [ :user_id, :tenor_gif_id ], unique: true
    add_index :gif_favorites, [ :user_id, :gif_collection_id, :tenor_gif_id ], unique: true,
              name: "index_gif_favorites_on_user_collection_tenor"
  end
end
