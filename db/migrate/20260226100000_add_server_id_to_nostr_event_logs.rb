class AddServerIdToNostrEventLogs < ActiveRecord::Migration[8.0]
  def change
    add_reference :nostr_event_logs, :server, null: true, foreign_key: true
  end
end
