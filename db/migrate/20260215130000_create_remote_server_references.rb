class CreateRemoteServerReferences < ActiveRecord::Migration[7.1]
  def change
    create_table :remote_server_references do |t|
      t.references :user, null: false, foreign_key: true
      t.string :remote_instance_url, null: false
      t.string :remote_server_id, null: false
      t.string :invite_code
      t.string :name
      t.string :icon_url
      t.integer :position, default: 0
      t.timestamps
    end

    add_index :remote_server_references, [ :user_id, :remote_instance_url, :remote_server_id ],
              unique: true, name: "idx_remote_server_refs_unique"
  end
end
