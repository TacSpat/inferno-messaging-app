class AddRemoteColumnsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :remote, :boolean, default: false, null: false
    add_reference :users, :remote_user_detail, foreign_key: { to_table: :remote_users }
  end
end
