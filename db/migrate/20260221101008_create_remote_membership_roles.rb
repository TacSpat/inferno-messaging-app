class CreateRemoteMembershipRoles < ActiveRecord::Migration[8.1]
  def change
    create_table :remote_membership_roles do |t|
      t.references :remote_member, null: false, foreign_key: true
      t.references :role, null: false, foreign_key: true

      t.timestamps
    end

    add_index :remote_membership_roles, [ :remote_member_id, :role_id ], unique: true
  end
end
