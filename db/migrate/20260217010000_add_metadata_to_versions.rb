class AddMetadataToVersions < ActiveRecord::Migration[8.0]
  def change
    add_column :versions, :remote_domain, :string
    add_column :versions, :ip_address, :string
    add_column :versions, :metadata, :json

    add_index :versions, :remote_domain, where: "remote_domain IS NOT NULL"
    add_index :versions, :created_at
  end
end
