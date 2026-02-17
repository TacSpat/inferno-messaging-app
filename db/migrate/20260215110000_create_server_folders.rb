class CreateServerFolders < ActiveRecord::Migration[8.0]
  def change
    create_table :server_folders do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false, default: "Folder", limit: 50
      t.integer :position, null: false, default: 0
      t.string :public_id, limit: 12, null: false
      t.boolean :collapsed, null: false, default: true
      t.timestamps
    end
    add_index :server_folders, :public_id, unique: true
    add_index :server_folders, [ :user_id, :position ]
  end
end
