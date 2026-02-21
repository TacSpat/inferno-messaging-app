class AddNostrFieldsToServers < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :nostr_group_id, :string
    add_column :servers, :relay_urls, :json
  end
end
