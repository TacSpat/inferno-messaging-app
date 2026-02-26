class CreateVoiceShowcases < ActiveRecord::Migration[8.0]
  def change
    create_table :voice_showcases do |t|
      t.references :server, null: false, foreign_key: true
      t.references :parent_channel, null: false, foreign_key: { to_table: :channels }
      t.references :child_channel, null: false, foreign_key: { to_table: :channels }
      t.references :user, foreign_key: true
      t.references :approved_by, foreign_key: { to_table: :users }
      t.timestamps
    end
  end
end
