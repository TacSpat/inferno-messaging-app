class CreateCalls < ActiveRecord::Migration[8.0]
  def change
    create_table :calls do |t|
      t.string :public_id, limit: 12, null: false
      t.references :conversation, null: false, foreign_key: true
      t.references :initiated_by, null: false, foreign_key: { to_table: :users }
      t.string :status, default: "ringing"
      t.string :livekit_room_name
      t.datetime :started_at
      t.datetime :ended_at
      t.timestamps
      t.index :public_id, unique: true
      t.index [ :conversation_id, :status ]
    end
  end
end
