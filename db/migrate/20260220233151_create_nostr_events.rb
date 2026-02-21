class CreateNostrEvents < ActiveRecord::Migration[8.1]
  def change
    create_table :nostr_events do |t|
      t.string :event_id, null: false
      t.integer :kind, null: false
      t.string :pubkey, null: false
      t.text :content
      t.json :tags
      t.string :sig, null: false
      t.datetime :event_created_at, null: false

      t.timestamps
    end

    add_index :nostr_events, :event_id, unique: true
    add_index :nostr_events, :kind
    add_index :nostr_events, :pubkey
    add_index :nostr_events, [:kind, :pubkey]
  end
end
