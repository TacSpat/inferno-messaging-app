class Contact < ApplicationRecord
  FRIENDSHIP_STATUSES = { not_friend: 0, pending_outgoing: 1, pending_incoming: 2, accepted: 3, declined: 4 }.freeze

  enum :friendship_status, FRIENDSHIP_STATUSES

  validates :pubkey, presence: true, uniqueness: true
  validates :friendship_status, presence: true

  scope :friends, -> { where(friendship_status: :accepted) }
  scope :pending_outgoing, -> { where(friendship_status: :pending_outgoing) }
  scope :pending_incoming, -> { where(friendship_status: :pending_incoming) }

  def npub
    Nostr::Bech32.encode_npub(pubkey)
  rescue
    nil
  end

  def effective_display_name
    petname.presence || display_name.presence || npub&.then { |n| "#{n[0..12]}..." } || pubkey[0..8]
  end

  def online?
    last_seen_at.present? && last_seen_at > 5.minutes.ago
  end

  def profile_stale?
    profile_fetched_at.nil? || profile_fetched_at < 1.hour.ago
  end

  # Update from a Kind 0 metadata event
  def update_from_metadata(metadata)
    update(
      display_name: metadata["display_name"].presence || metadata["name"],
      avatar_url: metadata["picture"],
      bio: metadata["about"],
      nip05: metadata["nip05"],
      profile_fetched_at: Time.current
    )
  end
end
