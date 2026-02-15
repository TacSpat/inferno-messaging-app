class AddSharedChannelFields < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :shared, :boolean, default: false
    add_column :channels, :nostr_group_id, :string
    add_column :channels, :nostr_relay_url, :string

    add_index :channels, :nostr_group_id
  end
end
