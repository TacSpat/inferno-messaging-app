class CreateMembershipRoles < ActiveRecord::Migration[8.0]
  def up
    create_table :membership_roles do |t|
      t.bigint :server_membership_id, null: false
      t.bigint :role_id, null: false
      t.timestamps
    end

    add_index :membership_roles, [:server_membership_id, :role_id], unique: true
    add_index :membership_roles, :role_id
    add_foreign_key :membership_roles, :server_memberships
    add_foreign_key :membership_roles, :roles

    # Migrate existing role assignments (skip @everyone — it's now implicit)
    execute <<~SQL
      INSERT INTO membership_roles (server_membership_id, role_id, created_at, updated_at)
      SELECT sm.id, sm.role_id, NOW(), NOW()
      FROM server_memberships sm
      JOIN roles r ON r.id = sm.role_id
      WHERE sm.role_id IS NOT NULL
        AND r.name != '@everyone'
    SQL

    remove_foreign_key :server_memberships, :roles
    remove_index :server_memberships, :role_id
    remove_column :server_memberships, :role_id
  end

  def down
    add_column :server_memberships, :role_id, :bigint
    add_index :server_memberships, :role_id
    add_foreign_key :server_memberships, :roles

    # Restore: pick the highest-position role from the join table, or fall back to @everyone
    execute <<~SQL
      UPDATE server_memberships sm
      SET role_id = COALESCE(
        (SELECT mr.role_id FROM membership_roles mr
         JOIN roles r ON r.id = mr.role_id
         WHERE mr.server_membership_id = sm.id
         ORDER BY r.position DESC LIMIT 1),
        (SELECT r.id FROM roles r WHERE r.server_id = sm.server_id AND r.name = '@everyone' LIMIT 1)
      )
    SQL

    drop_table :membership_roles
  end
end
