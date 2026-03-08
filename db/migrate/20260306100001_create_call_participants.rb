class CreateCallParticipants < ActiveRecord::Migration[8.0]
  def change
    create_table :call_participants do |t|
      t.references :call, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.datetime :joined_at
      t.datetime :left_at
      t.integer :duration_seconds
      t.timestamps
      t.index [:call_id, :user_id], unique: true
    end
  end
end
