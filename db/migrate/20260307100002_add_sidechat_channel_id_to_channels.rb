class AddSidechatChannelIdToChannels < ActiveRecord::Migration[8.0]
  def change
    add_reference :channels, :sidechat_channel, foreign_key: { to_table: :channels }, null: true
  end
end
