class AddStatusToContacts < ActiveRecord::Migration[8.1]
  def change
    add_column :contacts, :status, :string
    add_column :contacts, :status_emoji, :string
  end
end
