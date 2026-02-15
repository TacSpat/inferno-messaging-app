class AddDiscriminatorToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :discriminator, :string, limit: 4, null: false, default: "0000"

    # Remove old unique index on username alone
    remove_index :users, :username

    # Username + discriminator must be unique together
    add_index :users, [:username, :discriminator], unique: true
  end
end
