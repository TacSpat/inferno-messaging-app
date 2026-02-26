class AddPublicIdToVoiceShowcases < ActiveRecord::Migration[8.0]
  def change
    add_column :voice_showcases, :public_id, :string
    add_index :voice_showcases, :public_id, unique: true
  end
end
