class CreateRemoteFriendReferences < ActiveRecord::Migration[8.0]
  def change
    create_table :remote_friend_references do |t|
      t.references :user, null: false, foreign_key: true
      t.string :remote_instance_url, null: false
      t.string :friend_username
      t.string :friend_display_name
      t.string :friend_discriminator
      t.string :friend_avatar_url
      t.string :friend_profile_color
      t.string :friend_public_key
      t.string :online_state, default: "offline"

      t.timestamps
    end

    add_index :remote_friend_references, [ :user_id, :remote_instance_url, :friend_public_key ],
              unique: true, name: "idx_remote_friends_unique"
  end
end
