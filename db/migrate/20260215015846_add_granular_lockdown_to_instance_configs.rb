class AddGranularLockdownToInstanceConfigs < ActiveRecord::Migration[8.0]
  def change
    add_column :instance_configs, :lockdown_remote_auth, :boolean, default: false, null: false
    add_column :instance_configs, :lockdown_remote_joins, :boolean, default: false, null: false
    add_column :instance_configs, :lockdown_local_signups, :boolean, default: false, null: false
    add_column :instance_configs, :lockdown_invite_creation, :boolean, default: false, null: false
  end
end
