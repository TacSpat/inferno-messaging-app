class AddProfileFieldsToContacts < ActiveRecord::Migration[8.1]
  def change
    add_column :contacts, :banner_url, :string
    add_column :contacts, :username, :string
  end
end
