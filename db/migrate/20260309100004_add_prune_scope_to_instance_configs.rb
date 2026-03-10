class AddPruneScopeToInstanceConfigs < ActiveRecord::Migration[8.1]
  def change
    add_column :instance_configs, :prune_channel_messages, :boolean, default: true
    add_column :instance_configs, :prune_dm_messages, :boolean, default: true
  end
end
