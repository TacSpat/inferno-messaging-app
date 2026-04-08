class Reaction < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :message

  validates :emoji, presence: true
  # Unique by user_id OR reactor_pubkey per message+emoji
  validates :user_id, uniqueness: { scope: [ :message_id, :emoji ] }, allow_nil: true
  validates :reactor_pubkey, uniqueness: { scope: [ :message_id, :emoji ] }, allow_nil: true
end
