class BackfillRolePermissions < ActiveRecord::Migration[8.0]
  def up
    # Backfill existing @everyone roles with any missing default permissions
    Role.where(name: "@everyone").find_each do |role|
      next unless role.permissions.is_a?(Hash)
      updated = Role::DEFAULT_PERMISSIONS.stringify_keys.merge(role.permissions)
      role.update_column(:permissions, updated)
    end

    # Backfill existing Admin roles with any missing admin permissions
    Role.where(name: "Admin").find_each do |role|
      next unless role.permissions.is_a?(Hash)
      updated = Role::ADMIN_PERMISSIONS.stringify_keys.merge(role.permissions)
      role.update_column(:permissions, updated)
    end

    # Backfill existing Owner roles with any missing owner permissions
    Role.where(name: "Owner").find_each do |role|
      next unless role.permissions.is_a?(Hash)
      updated = Role::OWNER_PERMISSIONS.stringify_keys.merge(role.permissions)
      role.update_column(:permissions, updated)
    end
  end

  def down
    # No-op: can't reliably revert permission changes
  end
end
