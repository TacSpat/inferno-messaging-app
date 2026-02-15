class CreateInstanceConfigs < ActiveRecord::Migration[8.0]
  def change
    create_table :instance_configs do |t|
      # Instance identity
      t.string :instance_name, default: "Inferno Chat"
      t.text :instance_description

      # User limits
      t.integer :max_users, default: 0               # 0 = unlimited
      t.integer :max_servers_per_user, default: 5

      # Server limits
      t.integer :max_servers, default: 0              # 0 = unlimited
      t.integer :max_channels_per_server, default: 50
      t.integer :max_categories_per_server, default: 20
      t.integer :max_members_per_server, default: 0   # 0 = unlimited
      t.integer :max_roles_per_server, default: 25

      # Storage limits
      t.integer :max_upload_size_mb, default: 25
      t.integer :max_storage_per_user_mb, default: 0  # 0 = unlimited

      # Message pruning
      t.string :pruning_strategy, default: "none"     # none, time_based, storage_based
      t.integer :message_retention_days, default: 0   # 0 = forever
      t.integer :attachment_retention_days, default: 0 # 0 = forever
      t.boolean :keep_pinned_messages, default: true

      t.timestamps
    end
  end
end
