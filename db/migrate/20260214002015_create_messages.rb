class CreateMessages < ActiveRecord::Migration[8.0]
  def change
    create_table :messages do |t|
      t.text :content
      t.datetime :edited_at
      t.boolean :pinned
      t.references :user, null: false, foreign_key: true
      t.references :channel, null: false, foreign_key: true
      t.references :parent, foreign_key: { to_table: :messages }

      t.timestamps
    end
  end
end
