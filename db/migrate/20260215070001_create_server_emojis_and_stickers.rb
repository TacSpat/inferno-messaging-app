class CreateServerEmojisAndStickers < ActiveRecord::Migration[8.0]
  def change
    create_table :server_emojis do |t|
      t.references :server, null: false, foreign_key: true
      t.references :creator, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false, limit: 32
      t.string :public_id, limit: 12, null: false
      t.timestamps
    end
    add_index :server_emojis, :public_id, unique: true
    add_index :server_emojis, [:server_id, :name], unique: true

    create_table :server_stickers do |t|
      t.references :server, null: false, foreign_key: true
      t.references :creator, null: false, foreign_key: { to_table: :users }
      t.string :name, null: false, limit: 50
      t.string :description, limit: 100
      t.string :public_id, limit: 12, null: false
      t.timestamps
    end
    add_index :server_stickers, :public_id, unique: true
    add_index :server_stickers, [:server_id, :name], unique: true
  end
end
