class AddCacheSettingsToInstanceConfigs < ActiveRecord::Migration[8.0]
  def change
    add_column :instance_configs, :max_cache_size_mb, :integer, default: 500
    add_column :instance_configs, :backfill_days, :integer, default: 30
    add_column :instance_configs, :backfill_enabled, :boolean, default: true
  end
end
