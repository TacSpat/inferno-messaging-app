class AddFederationSettingsToInstanceConfigs < ActiveRecord::Migration[8.0]
  def change
    add_column :instance_configs, :federation_mode, :string, default: "open", null: false
    add_column :instance_configs, :lockdown_enabled, :boolean, default: false, null: false
    add_column :instance_configs, :instance_relay_url, :string
  end
end
