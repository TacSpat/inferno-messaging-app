# Verifies that a Nostr event signer has the required permission
# for a given server action.
#
# Usage:
#   NostrServerAuth.authorized?(server, signer_pubkey, "manage_channels")
#
class NostrServerAuth
  # Check if a pubkey has the required permission on a server
  def self.authorized?(server, signer_pubkey, required_permission)
    return false if signer_pubkey.blank?

    # Owner is always authorized
    return true if server.owner&.nostr_public_key == signer_pubkey

    # Find the member by pubkey (local first, then remote)
    membership = server.server_memberships
                       .joins(:user)
                       .find_by(users: { nostr_public_key: signer_pubkey })
    membership ||= server.remote_members.find_by(pubkey: signer_pubkey)
    return false unless membership

    # Admin has almost all permissions
    return true if membership.admin?

    # Check specific permission
    membership.has_permission?(required_permission)
  end

  # Map event kinds to required permissions
  PERMISSION_FOR_KIND = {
    31750 => "manage_server",
    31751 => "manage_channels",
    31752 => "manage_roles",
    31753 => "manage_roles",   # member management (self-join handled separately)
    31754 => "manage_emojis",
    31755 => "manage_emojis",
    31756 => "ban_members",
    31757 => "create_invite"
  }.freeze

  def self.permission_for_kind(kind)
    PERMISSION_FOR_KIND[kind]
  end

  # Check authorization for an inbound event, with special cases
  def self.authorized_for_event?(server, event)
    # During initial sync/bootstrap, skip auth — relay events are trusted
    return true if Thread.current[:nostr_skip_auth]

    signer_pubkey = event["pubkey"]
    kind = event["kind"]

    # Owner is always authorized
    return true if server.owner&.nostr_public_key == signer_pubkey

    # Special case: Kind 31753 (member) — users can publish their own join/leave
    if kind == 31753
      p_tag = (event["tags"] || []).find { |t| t[0] == "p" }
      target_pubkey = p_tag&.dig(1)
      # Self-join or self-leave is always allowed
      return true if target_pubkey == signer_pubkey
    end

    permission = permission_for_kind(kind)
    return true unless permission

    authorized?(server, signer_pubkey, permission)
  end
end
