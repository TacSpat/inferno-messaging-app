class AddLivekitToInstanceConfigs < ActiveRecord::Migration[8.1]
  def change
    add_column :instance_configs, :livekit_url, :string
    add_column :instance_configs, :livekit_api_key, :string
    add_column :instance_configs, :livekit_api_secret_enc, :text
    add_column :instance_configs, :livekit_verified, :boolean, default: false
    add_column :instance_configs, :livekit_verified_at, :datetime
  end
end
