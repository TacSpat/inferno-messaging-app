class CreateNostrEventLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :nostr_event_logs do |t|
      t.string :event_id, null: false
      t.integer :kind, null: false
      t.string :pubkey, null: false
      t.references :message, foreign_key: true
      t.references :channel, foreign_key: true
      t.string :direction, null: false
      t.datetime :event_created_at

      t.timestamps
    end

    add_index :nostr_event_logs, :event_id, unique: true
  end
end
