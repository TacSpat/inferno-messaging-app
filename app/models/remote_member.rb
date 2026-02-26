class RemoteMember < ApplicationRecord
  include HasPublicId
  include MemberInterface

  belongs_to :server
  has_many :remote_membership_roles, dependent: :destroy
  has_many :roles, through: :remote_membership_roles

  enum :online_state, { offline: 0, online: 1, idle: 2, dnd: 3, invisible: 4 }

  validates :pubkey, presence: true, uniqueness: { scope: :server_id }

  def top_role
    roles.ordered.first
  end

  def top_hoisted_role
    roles.select { |r| r.hoist? && r.name != "New Role" && !r.owner? }.max_by(&:position)
  end

  def has_permission?(permission)
    everyone_role = server.roles.find_by(name: "@everyone")
    return true if everyone_role&.has_permission?(permission)
    roles.any? { |r| r.has_permission?(permission) }
  end

  def nostr_public_key
    pubkey
  end

  def npub
    return nil if pubkey.blank?
    Nostr::Bech32.encode_npub(pubkey)
  end

  def owner?
    false
  end

  def admin?
    roles.any?(&:admin?)
  end

  def profile_stale?
    profile_fetched_at.nil? || profile_fetched_at < 1.hour.ago
  end

  def update_from_metadata(metadata)
    pic = metadata["picture"]
    ban = metadata["banner"]
    update(
      display_name: metadata["display_name"].presence || metadata["name"],
      username: metadata["name"],
      avatar_url: pic.present? ? (RemoteAssetCache.cache(pic) || pic) : avatar_url,
      banner_url: ban.present? ? (RemoteAssetCache.cache(ban) || ban) : banner_url,
      bio: metadata["about"],
      nip05: metadata["nip05"],
      profile_fetched_at: Time.current
    )
  end
end
