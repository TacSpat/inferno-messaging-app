class AddFederationCallbackTokenToFriendships < ActiveRecord::Migration[8.0]
  def change
    add_column :friendships, :federation_callback_token, :string
  end
end
