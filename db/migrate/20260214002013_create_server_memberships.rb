class CreateServerMemberships < ActiveRecord::Migration[8.0]
  def change
    create_table :server_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :server, null: false, foreign_key: true
      t.references :role, foreign_key: true
      t.string :nickname
      t.datetime :joined_at

      t.timestamps
    end

    add_index :server_memberships, [ :user_id, :server_id ], unique: true
  end
end
