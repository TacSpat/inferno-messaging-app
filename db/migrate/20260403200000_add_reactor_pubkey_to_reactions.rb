class AddReactorPubkeyToReactions < ActiveRecord::Migration[7.1]
  def change
    add_column :reactions, :reactor_pubkey, :string
    change_column_null :reactions, :user_id, true
  end
end
