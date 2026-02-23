class AddProviderPubkeyToServerVoiceProviders < ActiveRecord::Migration[8.1]
  def change
    add_column :server_voice_providers, :provider_pubkey, :string
    change_column_null :server_voice_providers, :user_id, true
    add_index :server_voice_providers, [:server_id, :provider_pubkey], unique: true,
              name: "idx_svp_on_server_id_and_provider_pubkey"

    # Remove the old foreign key constraint that requires user_id to be non-null
    remove_foreign_key :server_voice_providers, :users
    add_foreign_key :server_voice_providers, :users, on_delete: :nullify
  end
end
