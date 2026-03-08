class AddContactToConversationParticipants < ActiveRecord::Migration[8.0]
  def change
    add_reference :conversation_participants, :contact, null: true, foreign_key: true
    change_column_null :conversation_participants, :user_id, true

    # Remove the old unique index (user_id + conversation_id) and replace
    # with a partial index so the constraint only applies when user_id is present.
    remove_index :conversation_participants, [:conversation_id, :user_id], if_exists: true
    add_index :conversation_participants, [:conversation_id, :user_id],
              unique: true, where: "user_id IS NOT NULL",
              name: "idx_conv_participants_on_conv_and_user"
    add_index :conversation_participants, [:conversation_id, :contact_id],
              unique: true, where: "contact_id IS NOT NULL",
              name: "idx_conv_participants_on_conv_and_contact"
  end
end
