class AddSpoilerToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :spoiler, :boolean, default: false, null: false
  end
end
