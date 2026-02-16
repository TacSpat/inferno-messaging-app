class AddProfileFieldsToRemoteUsers < ActiveRecord::Migration[8.0]
  def change
    change_table :remote_users do |t|
      t.string :banner_url
      t.string :profile_color
      t.string :profile_color_2
      t.integer :banner_offset_y
      t.string :status
      t.string :status_emoji
      t.string :discriminator, limit: 4
      t.datetime :last_profile_sync_at
    end
  end
end
