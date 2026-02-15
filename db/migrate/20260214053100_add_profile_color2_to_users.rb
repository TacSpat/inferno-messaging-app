class AddProfileColor2ToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :profile_color_2, :string
  end
end
