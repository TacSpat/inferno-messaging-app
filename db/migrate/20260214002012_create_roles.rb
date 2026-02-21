class CreateRoles < ActiveRecord::Migration[8.0]
  def change
    create_table :roles do |t|
      t.string :name
      t.string :color
      t.integer :position
      t.boolean :mentionable
      t.json :permissions
      t.references :server, null: false, foreign_key: true

      t.timestamps
    end
  end
end
