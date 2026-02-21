class AddCounterpartyPubkeyToConversations < ActiveRecord::Migration[8.1]
  def change
    add_column :conversations, :counterparty_pubkey, :string
  end
end
