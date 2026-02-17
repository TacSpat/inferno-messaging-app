class CreateInvites < ActiveRecord::Migration[8.0]
  def change
    create_table :invites do |t|
      t.string :code, null: false
      t.references :server, null: false, foreign_key: true
      t.references :creator, null: false, foreign_key: { to_table: :users }
      t.integer :max_uses
      t.integer :uses_count, null: false, default: 0
      t.datetime :expires_at
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :invites, :code, unique: true
    add_index :invites, [ :server_id, :active ]

    # Migrate existing invite codes to Invite records
    reversible do |dir|
      dir.up do
        execute <<-SQL
          INSERT INTO invites (code, server_id, creator_id, active, uses_count, created_at, updated_at)
          SELECT invite_code, id, owner_id, true, 0, created_at, NOW()
          FROM servers
          WHERE invite_code IS NOT NULL
        SQL
      end
    end
  end
end
