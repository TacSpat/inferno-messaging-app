class AddColorToServerFolders < ActiveRecord::Migration[8.0]
  def change
    add_column :server_folders, :color, :string, limit: 7, default: "#4f545c"
  end
end
