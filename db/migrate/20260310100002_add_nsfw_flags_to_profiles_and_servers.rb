class AddNsfwFlagsToProfilesAndServers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :avatar_nsfw, :boolean, default: false, null: false
    add_column :users, :banner_nsfw, :boolean, default: false, null: false
    add_column :servers, :icon_nsfw, :boolean, default: false, null: false
    add_column :servers, :banner_nsfw, :boolean, default: false, null: false
  end
end
