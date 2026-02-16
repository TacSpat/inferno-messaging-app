class AddVoiceSettingsToInstanceConfigs < ActiveRecord::Migration[8.0]
  def change
    add_column :instance_configs, :voice_enabled, :boolean, default: false, null: false
    add_column :instance_configs, :max_voice_participants_per_channel, :integer, default: 25
  end
end
