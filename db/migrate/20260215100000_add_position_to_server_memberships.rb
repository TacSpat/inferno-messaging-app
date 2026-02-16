class AddPositionToServerMemberships < ActiveRecord::Migration[8.0]
  def up
    add_column :server_memberships, :position, :integer, default: 0, null: false

    # Backfill: for each user, order their memberships by joined_at and assign positions
    execute <<-SQL
      WITH ranked AS (
        SELECT id, ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY joined_at ASC) - 1 AS pos
        FROM server_memberships
      )
      UPDATE server_memberships
      SET position = ranked.pos
      FROM ranked
      WHERE server_memberships.id = ranked.id
    SQL
  end

  def down
    remove_column :server_memberships, :position
  end
end
