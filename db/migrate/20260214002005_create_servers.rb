class CreateServers < ActiveRecord::Migration[8.0]
  def change
    create_table :servers do |t|
      t.string :name
      t.text :description
      t.string :invite_code
      t.references :owner, null: false, foreign_key: { to_table: :users }

      t.timestamps
    end
    add_index :servers, :invite_code, unique: true
  end
end
