class AddWelcomeSettingsToServers < ActiveRecord::Migration[8.0]
  def change
    add_column :servers, :welcome_channel_id, :bigint
    add_column :servers, :welcome_message_enabled, :boolean, default: true
    add_column :servers, :welcome_message_template, :text, default: "Welcome to the server, {user}! 🎉"
    add_foreign_key :servers, :channels, column: :welcome_channel_id, on_delete: :nullify
    add_index :servers, :welcome_channel_id
  end
end
