class CreateVoiceStates < ActiveRecord::Migration[8.0]
  def change
    create_table :voice_states do |t|
      t.references :user, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.references :server, null: false, foreign_key: true
      t.boolean :self_mute, default: false, null: false
      t.boolean :self_deaf, default: false, null: false
      t.boolean :server_mute, default: false, null: false
      t.boolean :server_deaf, default: false, null: false
      t.boolean :video_on, default: false, null: false
      t.boolean :screen_share_on, default: false, null: false
      t.string :session_id, null: false
      t.string :public_id, limit: 12, null: false
      t.timestamps
    end

    add_index :voice_states, [ :user_id, :server_id ], unique: true
    add_index :voice_states, :public_id, unique: true
    add_index :voice_states, :session_id, unique: true
  end
end
