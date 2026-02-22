class AddEncryptionToChannels < ActiveRecord::Migration[8.1]
  def change
    add_column :channels, :encrypted, :boolean, default: false
    add_column :channels, :channel_public_key, :string
    add_column :channels, :encrypted_channel_private_key, :text
  end
end
