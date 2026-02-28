class Invite < ApplicationRecord
  belongs_to :server
  belongs_to :creator, class_name: "User"
  validates :code, presence: true, uniqueness: true

  before_validation :generate_code, on: :create

  scope :active_invites, -> { where(active: true).where("expires_at IS NULL OR expires_at > ?", Time.current) }

  def expired?
    expires_at.present? && expires_at <= Time.current
  end

  def maxed_out?
    max_uses.present? && uses_count >= max_uses
  end

  def usable?
    active? && !expired? && !maxed_out?
  end

  def increment_uses!
    increment!(:uses_count)
  end

  # Encode this invite as a nostr:naddr1... URI (NIP-19)
  # Uses a compact identifier: inv-{server_public_id}-{code}
  # No relay hints — the client resolves relays from its own config.
  def to_naddr
    return nil if server.nostr_group_id.blank?

    identifier = "inv-#{server.public_id}-#{code}"
    author_pubkey = creator&.nostr_public_key || server.owner&.nostr_public_key || ("0" * 64)

    naddr = Nostr::Bech32.encode_naddr(
      author: author_pubkey,
      kind: 31757,
      identifier: identifier,
      relays: []
    )
    "nostr:#{naddr}"
  end

  # The full d-tag used on relays (for publishing/querying)
  def relay_d_tag
    "inferno-invite-#{server.nostr_group_id}-#{code}"
  end

  # Decode a nostr:naddr1... URI into invite components.
  # Supports both compact (inv-{public_id}-{code}) and legacy (inferno-invite-{gid}-{code}) identifiers.
  def self.decode_naddr(naddr_uri)
    raw = naddr_uri.to_s.sub(/\Anostr:/, "")
    return nil unless raw.start_with?("naddr1")

    decoded = Nostr::Bech32.decode(raw)
    return nil unless decoded[:hrp] == "naddr"

    data = decoded[:data]
    identifier = data[:special]&.first || data[:identifier]&.first
    return nil if identifier.blank?

    # Compact format: inv-{public_id}-{code}
    if identifier.start_with?("inv-")
      match = identifier.match(/\Ainv-([a-zA-Z0-9]+)-([a-zA-Z0-9]+)\z/)
      return nil unless match
      server = Server.find_by(public_id: match[1])
      return nil unless server
      return {
        kind: 31757,
        identifier: identifier,
        nostr_group_id: server.nostr_group_id,
        code: match[2],
        author: data[:author]&.first,
        relays: data[:relay] || []
      }
    end

    # Legacy format: inferno-invite-{gid}-{code}
    if identifier.start_with?("inferno-invite-")
      parts = identifier.sub("inferno-invite-", "")
      gid_match = parts.match(/\A(inferno-[a-zA-Z0-9]+)-([a-zA-Z0-9]+)\z/)
      return nil unless gid_match
      return {
        kind: 31757,
        identifier: identifier,
        nostr_group_id: gid_match[1],
        code: gid_match[2],
        author: data[:author]&.first,
        relays: data[:relay] || []
      }
    end

    nil
  rescue => e
    Rails.logger.warn("[Invite] decode_naddr failed: #{e.message}")
    nil
  end

  private

  def generate_code
    self.code ||= SecureRandom.alphanumeric(8)
  end
end
