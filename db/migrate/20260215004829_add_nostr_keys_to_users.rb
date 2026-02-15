class AddNostrKeysToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :nostr_public_key, :string
    add_column :users, :nostr_encrypted_private_key, :text
    add_index :users, :nostr_public_key, unique: true
  end
end
