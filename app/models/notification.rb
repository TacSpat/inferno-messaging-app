class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :server
  belongs_to :channel
  belongs_to :message

  enum :notification_type, { mention: 0, role_mention: 1, everyone_mention: 2 }

  scope :unread, -> { where(read: false) }
  scope :for_server, ->(server_id) { where(server_id: server_id) }
  scope :for_channel, ->(channel_id) { where(channel_id: channel_id) }
end
