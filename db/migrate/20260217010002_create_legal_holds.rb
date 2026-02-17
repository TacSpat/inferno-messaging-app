class CreateLegalHolds < ActiveRecord::Migration[8.0]
  def change
    create_table :legal_holds do |t|
      t.string :holdable_type, null: false
      t.bigint :holdable_id, null: false
      t.references :placed_by, null: false, foreign_key: { to_table: :users }
      t.boolean :active, null: false, default: true
      t.datetime :placed_at, null: false
      t.datetime :lifted_at
      t.text :reason
      t.timestamps
    end

    add_index :legal_holds, [ :holdable_type, :holdable_id ],
              where: "active = true",
              unique: true,
              name: "index_legal_holds_active_unique"
    add_index :legal_holds, [ :holdable_type, :holdable_id ]
  end
end
