class AddServerTypeAndAgeRestriction < ActiveRecord::Migration[8.1]
  def change
    add_column :servers, :server_type, :string, default: "community"
    add_column :servers, :age_restricted, :boolean, default: false

    add_column :channels, :post_only, :boolean, default: false
  end
end
