class AddVoiceSettingsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :voice_settings, :jsonb, default: {}, null: false
  end
end
