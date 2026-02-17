class CreateGifCollectionsAndFavorites < ActiveRecord::Migration[8.0]
  def change
    create_table :gif_collections do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false, limit: 50
      t.integer :position, default: 0
      t.string :public_id, limit: 12, null: false
      t.timestamps
    end
    add_index :gif_collections, :public_id, unique: true
    add_index :gif_collections, [ :user_id, :name ], unique: true

    create_table :gif_favorites do |t|
      t.references :user, null: false, foreign_key: true
      t.references :gif_collection, null: false, foreign_key: true
      t.string :tenor_gif_id, null: false
      t.string :tenor_url, null: false
      t.string :preview_url, null: false
      t.string :gif_url, null: false
      t.string :description, limit: 100
      t.integer :position, default: 0
      t.string :public_id, limit: 12, null: false
      t.timestamps
    end
    add_index :gif_favorites, :public_id, unique: true
    add_index :gif_favorites, [ :user_id, :tenor_gif_id ], unique: true
  end
end
