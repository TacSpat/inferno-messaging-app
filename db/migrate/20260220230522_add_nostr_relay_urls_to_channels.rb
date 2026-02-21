class AddNostrRelayUrlsToChannels < ActiveRecord::Migration[8.1]
  def change
    add_column :channels, :nostr_relay_urls, :json
  end
end
