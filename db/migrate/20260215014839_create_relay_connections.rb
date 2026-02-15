class CreateRelayConnections < ActiveRecord::Migration[8.0]
  def change
    create_table :relay_connections do |t|
      t.string :url, null: false
      t.string :status, default: "active"
      t.datetime :last_connected_at
      t.datetime :last_error_at
      t.text :last_error_message

      t.timestamps
    end

    add_index :relay_connections, :url, unique: true
  end
end
