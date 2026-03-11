class AddTutorialHintsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :seen_hints, :json, default: [], null: false
    add_column :users, :tutorial_completed_at, :datetime
  end
end
