class CreateBans < ActiveRecord::Migration[8.0]
  def change
    create_table :bans do |t|
      t.references :server, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :banned_by, null: false, foreign_key: { to_table: :users }
      t.text :reason

      t.timestamps
    end

    add_index :bans, [:server_id, :user_id], unique: true
  end
end
