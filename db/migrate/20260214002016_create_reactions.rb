class CreateReactions < ActiveRecord::Migration[8.0]
  def change
    create_table :reactions do |t|
      t.string :emoji
      t.references :user, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true

      t.timestamps
    end

    add_index :reactions, [ :user_id, :message_id, :emoji ], unique: true
  end
end
