class AddTimedOutUntilToServerMemberships < ActiveRecord::Migration[8.1]
  def change
    add_column :server_memberships, :timed_out_until, :datetime, null: true
    add_column :server_memberships, :timed_out_by_id, :bigint, null: true
  end
end
