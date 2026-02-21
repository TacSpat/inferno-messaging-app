class AddNostrFieldsToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :nostr_event_id, :string
    add_index :messages, :nostr_event_id, unique: true
    add_column :messages, :nostr_event_json, :text
  end
end
