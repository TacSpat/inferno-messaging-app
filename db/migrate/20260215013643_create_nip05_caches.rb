class CreateNip05Caches < ActiveRecord::Migration[8.0]
  def change
    create_table :nip05_caches do |t|
      t.string :identifier, null: false
      t.string :public_key, null: false
      t.datetime :verified_at, null: false
      t.datetime :expires_at, null: false

      t.timestamps
    end

    add_index :nip05_caches, :identifier, unique: true
    add_index :nip05_caches, :public_key
  end
end
