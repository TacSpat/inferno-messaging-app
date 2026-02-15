class CreateConversations < ActiveRecord::Migration[8.0]
  def change
    create_table :conversations do |t|
      t.integer :kind, default: 0, null: false
      t.string :name
      t.timestamps
    end

    create_table :conversation_participants do |t|
      t.references :conversation, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.boolean :accepted, default: false, null: false
      t.boolean :muted, default: false, null: false
      t.datetime :last_read_at
      t.timestamps
    end

    add_index :conversation_participants, [:conversation_id, :user_id], unique: true

    add_reference :messages, :conversation, foreign_key: true, null: true
    change_column_null :messages, :channel_id, true
  end
end
