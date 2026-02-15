class CreateChannels < ActiveRecord::Migration[8.0]
  def change
    create_table :channels do |t|
      t.string :name
      t.text :topic
      t.integer :position
      t.integer :channel_type
      t.boolean :nsfw
      t.jsonb :permissions_overrides
      t.references :server, null: false, foreign_key: true

      t.timestamps
    end
  end
end
