class AddIsStickerToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :is_sticker, :boolean, default: false, null: false
  end
end
