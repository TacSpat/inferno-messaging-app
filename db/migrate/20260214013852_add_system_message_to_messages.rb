class AddSystemMessageToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :system_message, :boolean, default: false
  end
end
