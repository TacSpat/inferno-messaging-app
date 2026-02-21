class CreateRemoteMembers < ActiveRecord::Migration[8.1]
  def change
    create_table :remote_members do |t|
      t.string :pubkey, null: false
      t.references :server, null: false, foreign_key: true
      t.string :public_id

      # Profile fields (from Kind 0 metadata)
      t.string :display_name
      t.string :username
      t.string :avatar_url
      t.string :banner_url
      t.string :nip05
      t.string :profile_color
      t.string :profile_color_2
      t.text :bio

      # Server-specific
      t.string :nickname
      t.datetime :joined_at

      # Presence
      t.integer :online_state, default: 0, null: false
      t.string :status
      t.string :status_emoji
      t.datetime :last_seen_at

      # Cache control
      t.datetime :profile_fetched_at

      t.timestamps
    end

    add_index :remote_members, [:server_id, :pubkey], unique: true
    add_index :remote_members, :public_id, unique: true
  end
end
