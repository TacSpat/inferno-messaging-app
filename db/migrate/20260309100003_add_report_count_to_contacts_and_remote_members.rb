class AddReportCountToContactsAndRemoteMembers < ActiveRecord::Migration[8.0]
  def change
    add_column :contacts, :report_count, :integer, default: 0, null: false
    add_column :remote_members, :report_count, :integer, default: 0, null: false
  end
end
