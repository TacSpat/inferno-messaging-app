class AddCompositeIndexToMessages < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :messages, [ :channel_id, :created_at ], algorithm: :concurrently
  end
end
