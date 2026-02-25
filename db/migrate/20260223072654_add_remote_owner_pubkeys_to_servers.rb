class AddRemoteOwnerPubkeysToServers < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :remote_owner_pubkeys, :json, default: []
  end
end
