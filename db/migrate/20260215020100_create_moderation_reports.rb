class CreateModerationReports < ActiveRecord::Migration[8.0]
  def change
    create_table :moderation_reports do |t|
      t.references :reporter, null: false, foreign_key: { to_table: :users }
      t.string :reported_pubkey, null: false
      t.string :reported_event_id
      t.string :report_type, null: false
      t.text :reason
      t.string :status, default: "open", null: false
      t.references :reviewed_by, foreign_key: { to_table: :users }
      t.timestamps
    end

    add_index :moderation_reports, :reported_pubkey
    add_index :moderation_reports, :status
  end
end
