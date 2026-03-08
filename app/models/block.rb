class Block < ApplicationRecord
  belongs_to :blocker, class_name: "User"
  belongs_to :blocked, class_name: "User"

  validates :blocked_id, uniqueness: { scope: :blocker_id }
  validate :not_self

  after_create :sync_contact_blocked
  after_destroy :sync_contact_unblocked

  private

  def not_self
    errors.add(:blocked, "can't block yourself") if blocker_id == blocked_id
  end

  def sync_contact_blocked
    pubkey = blocked.nostr_public_key
    if pubkey.present?
      contact = Contact.find_or_initialize_by(pubkey: pubkey)
      contact.update!(friendship_status: :blocked)
    end
    publish_mute_list
  end

  def sync_contact_unblocked
    pubkey = blocked.nostr_public_key
    if pubkey.present?
      Contact.where(pubkey: pubkey, friendship_status: :blocked).update_all(friendship_status: :not_friend)
    end
    publish_mute_list
  end

  def publish_mute_list
    NostrPublishJob.perform_later(blocker.id, :mute_list)
  end
end
