class CreateNostrAuthChallenges < ActiveRecord::Migration[8.0]
  def change
    create_table :nostr_auth_challenges do |t|
      t.string :nonce, null: false
      t.string :requesting_domain, null: false
      t.string :callback_url, null: false
      t.datetime :expires_at, null: false
      t.boolean :used, default: false

      t.timestamps
    end

    add_index :nostr_auth_challenges, :nonce, unique: true
  end
end
