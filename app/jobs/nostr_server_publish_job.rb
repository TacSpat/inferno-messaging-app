# Publishes server state events to Nostr relays as parameterized replaceable events.
#
# Usage:
#   NostrServerPublishJob.perform_later(user_id, server_id, :metadata)
#   NostrServerPublishJob.perform_later(user_id, server_id, :member, pubkey: "abc123")
#   NostrServerPublishJob.perform_later(user_id, server_id, :ban, pubkey: "abc123")
#
class NostrServerPublishJob < ApplicationJob
  queue_as :default

  # Kind numbers for server state events (parameterized replaceable, 30000-39999)
  KIND_SERVER_METADATA  = 31750
  KIND_SERVER_STRUCTURE = 31751
  KIND_SERVER_ROLES     = 31752
  KIND_SERVER_MEMBER    = 31753
  KIND_SERVER_EMOJIS    = 31754
  KIND_SERVER_STICKERS  = 31755
  KIND_SERVER_BAN       = 31756
  KIND_SERVER_INVITE    = 31757

  PERMISSION_MAP = {
    metadata:  "manage_server",
    structure: "manage_channels",
    roles:     "manage_roles",
    member:    "manage_roles",
    emojis:    "manage_emojis",
    stickers:  "manage_emojis",
    ban:       "ban_members",
    invite:    "create_invite"
  }.freeze

  def perform(user_id, server_id, event_type, **options)
    @user = User.find_by(id: user_id)
    @server = Server.find_by(id: server_id)
    return unless @user && @server
    return if @user.nostr_public_key.blank?

    event_type = event_type.to_sym

    tags = build_tags(event_type, **options)
    return unless tags

    kind = kind_for(event_type)
    signer = Nostr::Signer.new(private_key: @user.nostr_private_key)
    event = Nostr::Event.new(
      kind: kind,
      pubkey: @user.nostr_public_key,
      content: "",
      tags: tags
    )
    signed = signer.sign(event)
    signed_hash = signed.to_json

    RelayService.publish_to_all(signed_hash)

    NostrEventLog.create!(
      event_id: signed.id,
      kind: kind,
      pubkey: @user.nostr_public_key,
      direction: "outbound",
      event_created_at: Time.at(signed.created_at || Time.current.to_i)
    )

    Rails.logger.info("[NostrServerPublishJob] Published kind #{kind} (#{event_type}) for server #{@server.nostr_group_id}")
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
    # Event already logged — ignore duplicate
  end

  private

  def kind_for(event_type)
    case event_type
    when :metadata  then KIND_SERVER_METADATA
    when :structure then KIND_SERVER_STRUCTURE
    when :roles     then KIND_SERVER_ROLES
    when :member    then KIND_SERVER_MEMBER
    when :emojis    then KIND_SERVER_EMOJIS
    when :stickers  then KIND_SERVER_STICKERS
    when :ban       then KIND_SERVER_BAN
    when :invite    then KIND_SERVER_INVITE
    end
  end

  def build_tags(event_type, **options)
    case event_type
    when :metadata  then build_metadata_tags(options)
    when :structure then build_structure_tags
    when :roles     then build_roles_tags
    when :member    then build_member_tags(options[:pubkey], options)
    when :emojis    then build_emojis_tags
    when :stickers  then build_stickers_tags
    when :ban       then build_ban_tags(options[:pubkey], options)
    when :invite    then build_invite_tags(options[:invite_code], options)
    end
  end

  # Kind 31750 — Server Metadata
  def build_metadata_tags(options = {})
    gid = @server.nostr_group_id
    tags = [["d", "inferno-#{gid}"]]
    tags << ["name", @server.name]
    tags << ["about", @server.description || ""]
    tags << ["owner", @server.owner.nostr_public_key] if @server.owner.nostr_public_key.present?

    if @server.icon.attached?
      tags << ["picture", blossom_url_for(@server.icon)]
    end
    if @server.banner.attached?
      tags << ["banner", blossom_url_for(@server.banner)]
    end

    @server.effective_relay_urls.each do |url|
      tags << ["relay", url]
    end

    if @server.welcome_channel
      tags << ["welcome_channel", @server.welcome_channel.nostr_group_id || ""]
    end
    tags << ["welcome_message", @server.welcome_message_template || ""]
    tags << ["welcome_enabled", @server.welcome_message_enabled?.to_s]

    tags << ["deleted", "true"] if options[:deleted]
    tags
  end

  # Kind 31751 — Server Structure (channels + categories + ordering)
  def build_structure_tags
    gid = @server.nostr_group_id
    tags = [
      ["d", "inferno-struct-#{gid}"],
      ["server", gid]
    ]

    @server.categories.ordered.each do |cat|
      tags << ["cat", cat.public_id, cat.name, cat.position.to_s]
    end

    @server.channels.ordered.includes(:category).each do |ch|
      perm_overrides = (ch.permissions_overrides || {}).to_json
      tags << [
        "ch",
        ch.public_id,
        ch.name,
        ch.channel_type,
        ch.position.to_s,
        ch.category&.public_id || "",
        ch.topic || "",
        ch.nsfw?.to_s,
        ch.nostr_group_id || "",
        perm_overrides,
        ch.encrypted?.to_s,
        ch.channel_public_key || ""
      ]
    end

    tags
  end

  # Kind 31752 — Server Roles
  def build_roles_tags
    gid = @server.nostr_group_id
    tags = [
      ["d", "inferno-roles-#{gid}"],
      ["server", gid]
    ]

    @server.roles.ordered.each do |role|
      tags << [
        "role",
        role.public_id,
        role.name,
        role.color || "#99aab5",
        role.position.to_s,
        (role.hoist? rescue false).to_s,
        (role.respond_to?(:mentionable?) ? role.mentionable?.to_s : "false"),
        (role.permissions || {}).to_json
      ]
    end

    tags
  end

  # Kind 31753 — Server Member (one event per member)
  def build_member_tags(target_pubkey, options = {})
    gid = @server.nostr_group_id
    return nil if target_pubkey.blank?

    d_tag = "inferno-mbr-#{gid}-#{target_pubkey[0..15]}"
    tags = [
      ["d", d_tag],
      ["server", gid],
      ["p", target_pubkey]
    ]

    if options[:removed]
      tags << ["removed", "true"]
      return tags
    end

    # Find the membership for this pubkey (local user first, then remote member)
    member_user = User.find_by(nostr_public_key: target_pubkey)
    if member_user
      membership = @server.server_memberships.find_by(user: member_user)
      if membership
        role_ids = membership.roles.pluck(:public_id)
        tags << (["roles"] + role_ids)
        tags << ["nickname", membership.nickname || ""]
        tags << ["joined_at", (membership.joined_at || membership.created_at).to_i.to_s]
      end

      # Embed profile data so remote instances don't need a separate Kind 0 fetch
      tags << ["profile_name", member_user.username || ""]
      tags << ["profile_display_name", member_user.display_name.presence || member_user.username || ""]
      tags << ["profile_about", member_user.bio || ""]
      if member_user.avatar.attached?
        tags << ["profile_picture", blossom_url_for(member_user.avatar)]
      end
      if member_user.banner.attached?
        tags << ["profile_banner", blossom_url_for(member_user.banner)]
      end
    else
      remote = @server.remote_members.find_by(pubkey: target_pubkey)
      if remote
        role_ids = remote.roles.pluck(:public_id)
        tags << (["roles"] + role_ids)
        tags << ["nickname", remote.nickname || ""]
        tags << ["joined_at", (remote.joined_at || remote.created_at).to_i.to_s]

        # Forward remote member's profile data
        tags << ["profile_name", remote.username || ""]
        tags << ["profile_display_name", remote.display_name || ""]
        tags << ["profile_about", remote.bio || ""]
        tags << ["profile_picture", remote.avatar_url || ""]
        tags << ["profile_banner", remote.banner_url || ""]
      end
    end

    tags
  end

  # Kind 31754 — Server Emojis
  def build_emojis_tags
    gid = @server.nostr_group_id
    tags = [
      ["d", "inferno-emojis-#{gid}"],
      ["server", gid]
    ]

    @server.server_emojis.includes(:creator, image_attachment: :blob).each do |emoji|
      next unless emoji.image.attached?
      url = blossom_url_for(emoji.image)
      creator_pk = emoji.creator&.nostr_public_key || ""
      tags << ["emoji", emoji.name, url, creator_pk]
    end

    tags
  end

  # Kind 31755 — Server Stickers
  def build_stickers_tags
    gid = @server.nostr_group_id
    tags = [
      ["d", "inferno-stickers-#{gid}"],
      ["server", gid]
    ]

    @server.server_stickers.includes(:creator, image_attachment: :blob).each do |sticker|
      next unless sticker.image.attached?
      url = blossom_url_for(sticker.image)
      creator_pk = sticker.creator&.nostr_public_key || ""
      tags << ["sticker", sticker.name, sticker.description || "", url, creator_pk]
    end

    tags
  end

  # Kind 31756 — Server Ban (one event per ban)
  def build_ban_tags(target_pubkey, options = {})
    gid = @server.nostr_group_id
    return nil if target_pubkey.blank?

    d_tag = "inferno-ban-#{gid}-#{target_pubkey[0..15]}"
    tags = [
      ["d", d_tag],
      ["server", gid],
      ["p", target_pubkey]
    ]

    if options[:unbanned]
      tags << ["unbanned", "true"]
      return tags
    end

    # Find ban record
    ban_user = User.find_by(nostr_public_key: target_pubkey)
    if ban_user
      ban = @server.bans.find_by(user: ban_user)
      if ban
        tags << ["reason", ban.reason || ""]
        tags << ["banned_by", ban.banned_by&.nostr_public_key || ""]
      end
    end

    tags
  end

  # Kind 31757 — Server Invite
  def build_invite_tags(invite_code, options = {})
    gid = @server.nostr_group_id
    return nil if invite_code.blank?

    invite = @server.invites.find_by(code: invite_code)
    return nil unless invite

    d_tag = "inferno-invite-#{gid}-#{invite_code}"
    tags = [
      ["d", d_tag],
      ["server", gid],
      ["code", invite.code]
    ]

    if options[:revoked]
      tags << ["revoked", "true"]
      return tags
    end

    tags << ["max_uses", (invite.max_uses || 0).to_s]
    tags << ["expires_at", (invite.expires_at&.to_i || 0).to_s]
    tags << ["created_by", invite.creator&.nostr_public_key || ""]
    tags << ["uses", invite.uses_count.to_s]

    tags
  end

  # Upload an Active Storage attachment to the local Blossom endpoint
  # and return a content-addressable URL.
  # Falls back to the Rails blob path if Blossom upload fails.
  def blossom_url_for(attachment)
    return "" unless attachment.attached?

    blob = attachment.blob
    hash = blob.checksum # Base64-encoded MD5 — we need SHA256 for Blossom
    ext = File.extname(blob.filename.to_s).presence || ".bin"

    # Try to use RemoteAssetCache-style local path
    # Compute SHA256 from the blob's content
    tempfile = blob.download
    sha256 = Digest::SHA256.hexdigest(tempfile)
    filename = "#{sha256}#{ext}"

    # Write to public/cached_assets for serving
    cache_dir = Rails.root.join("public", "cached_assets")
    FileUtils.mkdir_p(cache_dir)
    full_path = cache_dir.join(filename)
    File.binwrite(full_path, tempfile) unless File.exist?(full_path)

    # Return absolute URL so other instances can download this asset
    instance_domain = Rails.application.config.x.instance_domain
    scheme = instance_domain&.include?("localhost") || instance_domain&.match?(/:\d+$/) ? "http" : "https"
    "#{scheme}://#{instance_domain}/cached_assets/#{filename}"
  rescue => e
    Rails.logger.warn("[NostrServerPublishJob] Blossom upload failed: #{e.message}")
    instance_domain = Rails.application.config.x.instance_domain
    scheme = instance_domain&.include?("localhost") || instance_domain&.match?(/:\d+$/) ? "http" : "https"
    "#{scheme}://#{instance_domain}#{Rails.application.routes.url_helpers.rails_blob_path(attachment, only_path: true)}"
  end
end
