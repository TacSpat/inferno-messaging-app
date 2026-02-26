class AddBroadcastingToVoiceStates < ActiveRecord::Migration[8.0]
  def change
    add_column :voice_states, :broadcasting, :boolean, default: false, null: false
  end
end
