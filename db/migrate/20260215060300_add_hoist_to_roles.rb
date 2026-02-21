class AddHoistToRoles < ActiveRecord::Migration[8.0]
  def change
    add_column :roles, :hoist, :boolean, default: false, null: false

    # Hoist Owner and Admin roles by default
    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE roles SET hoist = 1
          WHERE json_extract(permissions, '$.owner') = 1
             OR json_extract(permissions, '$.administrator') = 1
        SQL
      end
    end
  end
end
