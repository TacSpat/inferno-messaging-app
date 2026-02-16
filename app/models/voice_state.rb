class VoiceState < ApplicationRecord
  include HasPublicId

  belongs_to :user
  belongs_to :channel
  belongs_to :server

  validates :user_id, uniqueness: { scope: :server_id, message: "can only be in one voice channel per server" }
  validates :session_id, presence: true, uniqueness: true
end
