class AddNostrAuthorPubkeyToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :nostr_author_pubkey, :string
  end
end
