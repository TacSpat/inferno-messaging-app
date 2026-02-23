class AddLivekitToUsersAndVoiceProviders < ActiveRecord::Migration[8.1]
  def change
    # User-level LiveKit credentials (private)
    add_column :users, :livekit_url, :string
    add_column :users, :livekit_api_key, :string
    add_column :users, :livekit_api_secret_enc, :text
    add_column :users, :livekit_verified, :boolean, default: false
    add_column :users, :livekit_verified_at, :datetime

    # Server voice toggle
    add_column :servers, :voice_enabled, :boolean, default: false

    # Channel's current voice provider assignment (cleared when channel empties)
    add_reference :channels, :current_voice_provider, foreign_key: { to_table: :users }, null: true

    # Community voice providers (opt-in per server)
    create_table :server_voice_providers do |t|
      t.references :server, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :position, default: 0, null: false
      t.boolean :active, default: true, null: false
      t.timestamps
    end

    add_index :server_voice_providers, [:server_id, :user_id], unique: true
  end
end
