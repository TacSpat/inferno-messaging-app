class AddVoiceSettingsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :voice_settings, :json, default: {}, null: false
  end
end
