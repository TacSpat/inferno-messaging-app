class AddParentChannelToChannels < ActiveRecord::Migration[8.0]
  def change
    add_column :channels, :parent_channel_id, :bigint, null: true
    add_index :channels, :parent_channel_id
    add_foreign_key :channels, :channels, column: :parent_channel_id, on_delete: :cascade
  end
end
