class CreateNotifications < ActiveRecord::Migration[8.0]
  def change
    create_table :notifications do |t|
      t.references :user, null: false, foreign_key: true
      t.references :server, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true
      t.integer :notification_type, default: 0, null: false
      t.boolean :read, default: false, null: false
      t.timestamps
    end
    add_index :notifications, [ :user_id, :read ]
    add_index :notifications, [ :user_id, :server_id, :read ]
    add_index :notifications, [ :user_id, :channel_id, :read ]
  end
end
