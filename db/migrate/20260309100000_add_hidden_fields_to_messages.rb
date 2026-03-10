class AddHiddenFieldsToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :hidden_at, :datetime
    add_column :messages, :hidden_by_id, :bigint
    add_column :messages, :hidden_reason, :string
    add_index :messages, :hidden_at, where: "hidden_at IS NOT NULL"
    add_foreign_key :messages, :users, column: :hidden_by_id
  end
end
