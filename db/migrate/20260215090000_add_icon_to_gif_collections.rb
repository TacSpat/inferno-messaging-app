class AddIconToGifCollections < ActiveRecord::Migration[8.0]
  def change
    add_column :gif_collections, :icon, :string, limit: 255
  end
end
