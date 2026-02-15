class AddInstanceAdminToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :instance_admin, :boolean, default: false, null: false
  end
end
