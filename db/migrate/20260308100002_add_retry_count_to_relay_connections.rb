class AddRetryCountToRelayConnections < ActiveRecord::Migration[7.1]
  def change
    add_column :relay_connections, :retry_count, :integer, default: 0
  end
end
