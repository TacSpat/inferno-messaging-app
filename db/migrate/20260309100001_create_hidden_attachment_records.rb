class CreateHiddenAttachmentRecords < ActiveRecord::Migration[8.0]
  def change
    create_table :hidden_attachment_records do |t|
      t.references :message, null: false, foreign_key: true
      t.string :original_filename, null: false
      t.string :content_type
      t.bigint :byte_size
      t.string :checksum
      t.datetime :purged_at, null: false
      t.references :purged_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
  end
end
