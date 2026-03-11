class AddSafetyProtectionLevel < ActiveRecord::Migration[8.1]
  def change
    add_column :instance_configs, :safety_protection_level, :string, default: "standard"
  end
end
