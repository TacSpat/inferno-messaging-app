# Duck-types the User interface so RemoteMember works in views
# that call member.avatar.attached?, member.display_name_for(server), etc.
module MemberInterface
  extend ActiveSupport::Concern

  # Null object for ActiveStorage attachment checks
  class NullAttachment
    def attached? = false
    def variant(*) = nil
  end

  NULL_ATTACHMENT = NullAttachment.new

  def avatar
    NULL_ATTACHMENT
  end

  def banner
    NULL_ATTACHMENT
  end

  def banner_offset_y
    0
  end

  def effective_avatar_url
    return nil if avatar_url.blank?
    return avatar_url if avatar_url.start_with?("/")
    RemoteAssetCache.cached_path(avatar_url) || avatar_url
  end

  def effective_banner_url
    return nil if banner_url.blank?
    return banner_url if banner_url.start_with?("/")
    RemoteAssetCache.cached_path(banner_url) || banner_url
  end

  def display_name_for(_server = nil)
    nickname.presence || display_name.presence || username.presence || pubkey[0..8]
  end

  def role_color_for(_server = nil)
    top_role&.color || "#ffffff"
  end

  def tag
    username.presence || pubkey[0..8]
  end

  def nostr_public_key
    pubkey
  end

  # Return [self] so `member.server_memberships.find { |sm| sm.server_id == server.id }`
  # works — RemoteMember itself acts as its own "membership" since it belongs_to :server.
  def server_memberships
    [ self ]
  end

  def remote?
    true
  end
end
