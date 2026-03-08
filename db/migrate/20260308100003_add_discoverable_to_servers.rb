class AddDiscoverableToServers < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :discoverable, :boolean, default: false, null: false
  end
end
