class AddAfkSettingsToServers < ActiveRecord::Migration[8.0]
  def change
    add_reference :servers, :afk_channel, foreign_key: { to_table: :channels, on_delete: :nullify }, null: true
    add_column :servers, :afk_timeout, :integer, default: 5, null: false
    add_column :servers, :afk_action, :string, default: "move", null: false
  end
end
