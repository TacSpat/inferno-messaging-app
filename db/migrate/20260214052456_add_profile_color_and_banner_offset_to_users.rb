class AddProfileColorAndBannerOffsetToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :profile_color, :string
    add_column :users, :banner_offset_y, :integer
  end
end
