class CreateUserSuspensions < ActiveRecord::Migration[8.0]
  def change
    create_table :user_suspensions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :suspension_type, null: false
      t.text :reason
      t.string :reason_category
      t.boolean :auto_triggered, default: false, null: false
      t.bigint :triggered_by_quarantine_id
      t.references :suspended_by, foreign_key: { to_table: :users }
      t.datetime :expires_at
      t.datetime :lifted_at
      t.references :lifted_by, foreign_key: { to_table: :users }
      t.text :lift_reason
      t.string :federation_broadcast_status, default: "not_applicable", null: false
      t.datetime :federation_broadcast_at

      t.timestamps
    end

    add_index :user_suspensions, [ :user_id, :lifted_at ]
    add_index :user_suspensions, :suspension_type
    add_index :user_suspensions, :reason_category
    add_index :user_suspensions, :expires_at, where: "lifted_at IS NULL", name: "index_user_suspensions_on_expires_at_active"
    add_index :user_suspensions, :created_at
  end
end
