class AddRoleTypeToRoles < ActiveRecord::Migration[8.0]
  def up
    add_column :roles, :role_type, :string, null: true

    # Mark existing Voice Provider roles
    Role.where(name: "Voice Provider").update_all(role_type: "voice_provider")
  end

  def down
    remove_column :roles, :role_type
  end
end
