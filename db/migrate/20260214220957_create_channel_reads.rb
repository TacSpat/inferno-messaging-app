class CreateChannelReads < ActiveRecord::Migration[8.0]
  def change
    create_table :channel_reads do |t|
      t.references :user, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.datetime :last_read_at, null: false

      t.timestamps
    end
    add_index :channel_reads, [ :user_id, :channel_id ], unique: true
  end
end
