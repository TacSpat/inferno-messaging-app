class AddVoiceFieldsToChannels < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :voice_bitrate, :integer, default: 64000
    add_column :channels, :voice_user_limit, :integer, default: 0
    add_column :channels, :video_enabled, :boolean, default: false
  end
end
