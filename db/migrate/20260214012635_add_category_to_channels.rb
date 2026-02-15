class AddCategoryToChannels < ActiveRecord::Migration[8.0]
  def change
    add_reference :channels, :category, null: true, foreign_key: true
  end
end
