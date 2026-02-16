class CreateRemoteConversationReferences < ActiveRecord::Migration[8.0]
  def change
    create_table :remote_conversation_references do |t|
      t.references :user, null: false, foreign_key: true
      t.string :remote_instance_url, null: false
      t.string :remote_conversation_id, null: false
      t.string :kind, default: "direct"
      t.string :name
      t.string :other_username
      t.string :other_display_name
      t.string :other_avatar_url
      t.string :other_profile_color
      t.datetime :last_message_at

      t.timestamps
    end

    add_index :remote_conversation_references, [:user_id, :remote_instance_url, :remote_conversation_id],
              unique: true, name: "idx_remote_conv_refs_unique"
  end
end
