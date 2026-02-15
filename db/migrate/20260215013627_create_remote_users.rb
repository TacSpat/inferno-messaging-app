class CreateRemoteUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :remote_users do |t|
      t.string :nostr_public_key, null: false
      t.string :home_instance, null: false
      t.string :display_name
      t.string :avatar_url
      t.text :bio
      t.string :username
      t.datetime :last_verified_at
      t.string :public_id, limit: 12

      t.timestamps
    end

    add_index :remote_users, :nostr_public_key, unique: true
    add_index :remote_users, :public_id, unique: true
    add_index :remote_users, :home_instance
  end
end
