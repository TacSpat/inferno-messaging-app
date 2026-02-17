class AddServerFolderToRemoteServerReferences < ActiveRecord::Migration[8.0]
  def change
    add_reference :remote_server_references, :server_folder, null: true, foreign_key: true
  end
end
