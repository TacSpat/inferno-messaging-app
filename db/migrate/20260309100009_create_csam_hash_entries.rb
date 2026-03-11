class CreateCsamHashEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :csam_hash_entries do |t|
      t.string :hash_value, null: false
      t.string :hash_type, null: false
      t.string :list_source
      t.datetime :added_at
      t.timestamps
      t.index [ :hash_value, :hash_type ], unique: true
      t.index :list_source
    end
  end
end
