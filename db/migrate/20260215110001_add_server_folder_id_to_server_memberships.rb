class AddServerFolderIdToServerMemberships < ActiveRecord::Migration[8.0]
  def change
    add_reference :server_memberships, :server_folder, null: true, foreign_key: true
  end
end
