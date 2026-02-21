class AddBlossomServerUrlsToInstanceConfigs < ActiveRecord::Migration[8.1]
  def change
    add_column :instance_configs, :blossom_server_urls, :json
  end
end
