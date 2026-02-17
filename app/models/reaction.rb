class Reaction < ApplicationRecord
  belongs_to :user
  belongs_to :message

  validates :emoji, presence: true
  validates :user_id, uniqueness: { scope: [ :message_id, :emoji ] }
end
