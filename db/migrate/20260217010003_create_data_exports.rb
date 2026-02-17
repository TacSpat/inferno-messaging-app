class CreateDataExports < ActiveRecord::Migration[8.0]
  def change
    create_table :data_exports do |t|
      t.references :user, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.string :export_type, null: false, default: "full"
      t.string :status, null: false, default: "pending"
      t.string :file_path
      t.datetime :expires_at
      t.timestamps
    end

    add_index :data_exports, :status
  end
end
