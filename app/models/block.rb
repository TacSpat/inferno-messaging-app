class Block < ApplicationRecord
  belongs_to :blocker, class_name: "User"
  belongs_to :blocked, class_name: "User"

  validates :blocked_id, uniqueness: { scope: :blocker_id }
  validate :not_self

  # Blocking removes any existing contact relationship
  after_create :remove_contact

  private

  def not_self
    errors.add(:blocked, "can't block yourself") if blocker_id == blocked_id
  end

  def remove_contact
    pubkey = blocked.nostr_public_key
    Contact.where(pubkey: pubkey).destroy_all if pubkey.present?
  end
end
