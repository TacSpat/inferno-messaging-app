class AddFederationTokenToRemoteUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :remote_users, :federation_token, :text
  end
end
