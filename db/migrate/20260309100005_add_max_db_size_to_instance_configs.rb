class AddMaxDbSizeToInstanceConfigs < ActiveRecord::Migration[8.1]
  def change
    add_column :instance_configs, :max_db_size_mb, :integer, default: 0
  end
end
