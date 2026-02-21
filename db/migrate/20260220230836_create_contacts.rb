class CreateContacts < ActiveRecord::Migration[8.1]
  def change
    create_table :contacts do |t|
      t.string :pubkey, null: false
      t.string :relay_url
      t.string :petname
      t.string :display_name
      t.string :avatar_url
      t.text :bio
      t.string :nip05
      t.datetime :last_seen_at
      t.integer :friendship_status, default: 0, null: false
      t.datetime :profile_fetched_at

      t.timestamps
    end

    add_index :contacts, :pubkey, unique: true
    add_index :contacts, :friendship_status
  end
end
