class CreateInstanceBlocklists < ActiveRecord::Migration[8.0]
  def change
    create_table :instance_blocklists do |t|
      t.string :domain, null: false
      t.text :reason
      t.references :blocked_by, null: false, foreign_key: { to_table: :users }
      t.datetime :blocked_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
    end

    add_index :instance_blocklists, :domain, unique: true
  end
end
