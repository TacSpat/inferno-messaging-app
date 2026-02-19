class Federation::ProfilesController < ApplicationController
  skip_before_action :verify_authenticity_token

  before_action :verify_federation_open
  before_action :check_blocklist
  before_action :verify_federation_token, except: [ :memberships ]

  # GET /federation/profiles/:pubkey?requesting_instance=example.com
  def show
    user = User.local.find_by(nostr_public_key: params[:pubkey])

    unless user
      render json: { error: "User not found" }, status: :not_found
      return
    end

    host = request.host_with_port
    instance_domain = Rails.application.config.x.instance_domain

    avatar_url = if user.avatar.attached?
      rails_blob_url(user.avatar, host: host,
                     protocol: Rails.env.development? ? "http" : "https")
    end

    banner_url = if user.banner.attached?
      rails_blob_url(user.banner, host: host,
                     protocol: Rails.env.development? ? "http" : "https")
    end

    render json: {
      pubkey: user.nostr_public_key,
      username: user.username,
      discriminator: user.discriminator,
      display_name: user.display_name,
      email: user.email,
      bio: user.bio,
      profile_color: user.profile_color,
      profile_color_2: user.profile_color_2,
      banner_offset_y: user.banner_offset_y,
      status: user.status,
      status_emoji: user.status_emoji,
      nip05: user.nip05_identifier,
      home_instance: instance_domain,
      avatar_url: avatar_url,
      banner_url: banner_url,
      synced_at: Time.current.iso8601
    }
  end

  # GET /federation/profiles/:pubkey/servers
  def servers
    user = find_local_user
    return unless user

    protocol = Rails.env.development? ? "http" : "https"
    host = request.host_with_port
    instance_url = "#{protocol}://#{host}"

    servers_data = user.server_memberships.includes(server: [ :invites, :server_emojis, :server_stickers, { icon_attachment: :blob } ]).map do |membership|
      server = membership.server
      invite = server.invites.first

      icon_url = if server.icon.attached?
        rails_blob_url(server.icon, host: host, protocol: protocol)
      end

      emojis = server.server_emojis.select { |e| e.image.attached? }.map do |emoji|
        {
          name: emoji.name,
          image_url: rails_blob_url(emoji.image, host: host, protocol: protocol)
        }
      end

      stickers = server.server_stickers.select { |s| s.image.attached? }.map do |sticker|
        {
          name: sticker.name,
          description: sticker.description,
          image_url: rails_blob_url(sticker.image, host: host, protocol: protocol)
        }
      end

      {
        server_id: server.public_id,
        name: server.name,
        icon_url: icon_url,
        invite_code: invite&.code,
        instance_url: instance_url,
        member_count: server.server_memberships.count,
        emojis: emojis,
        stickers: stickers
      }
    end

    render json: { servers: servers_data }
  end

  # GET /federation/profiles/:pubkey/conversations
  def conversations
    user = find_local_user
    return unless user

    protocol = Rails.env.development? ? "http" : "https"
    host = request.host_with_port
    instance_url = "#{protocol}://#{host}"

    conversations_data = user.conversations.includes(:participants, :messages).map do |conv|
      other = conv.direct? ? conv.other_user(user) : nil
      last_msg = conv.last_message

      other_data = if other
        avatar_url = if other.avatar.attached?
          rails_blob_url(other.avatar, host: host, protocol: protocol)
        end

        {
          username: other.username,
          display_name: other.display_name,
          avatar_url: avatar_url,
          profile_color: other.profile_color
        }
      end

      {
        conversation_id: conv.public_id,
        kind: conv.kind,
        name: conv.display_name(user),
        other_user: other_data,
        last_message_at: last_msg&.created_at&.iso8601,
        instance_url: instance_url
      }
    end

    render json: { conversations: conversations_data }
  end

  # POST /federation/profiles/:pubkey/report_memberships
  # Remote instances push their server list back to the home instance
  def report_memberships
    user = find_local_user
    return unless user

    servers = params[:servers] || []
    synced_ids = []

    servers.each do |server_data|
      instance_url = FederationService.normalize_instance_url_for_storage(
        server_data[:instance_url] || server_data["instance_url"]
      )
      ref = user.remote_server_references.find_or_initialize_by(
        remote_instance_url: instance_url,
        remote_server_id: server_data[:server_id] || server_data["server_id"]
      )
      ref.update!(
        name: server_data[:name],
        icon_url: server_data[:icon_url],
        invite_code: server_data[:invite_code]
      )
      synced_ids << ref.id
    end

    # Clean up stale references from the reporting instance
    raw_reporting_url = servers.first&.dig(:instance_url) || servers.first&.dig("instance_url")
    reporting_url = raw_reporting_url.present? ? FederationService.normalize_instance_url_for_storage(raw_reporting_url) : nil
    if reporting_url.present?
      user.remote_server_references
        .where(remote_instance_url: reporting_url)
        .where.not(id: synced_ids)
        .destroy_all
    end

    render json: { status: "ok", received: servers.size }
  end

  # GET /federation/profiles/:pubkey/memberships?requesting_instance=...
  # Returns the shadow user's local server memberships on this instance.
  # No federation token required — used by home instances to pull fresh data.
  # Protected by blocklist + federation-open checks only.
  def memberships
    user = User.find_by(nostr_public_key: params[:pubkey])
    unless user
      render json: { error: "User not found" }, status: :not_found
      return
    end

    protocol = Rails.env.development? ? "http" : "https"
    host = request.host_with_port
    instance_url = "#{protocol}://#{host}"

    servers_data = user.server_memberships.includes(server: [ :invites, { icon_attachment: :blob } ]).map do |membership|
      server = membership.server
      invite = server.invites.first
      icon_url = server.icon.attached? ? rails_blob_url(server.icon, host: host, protocol: protocol) : nil

      {
        server_id: server.public_id,
        name: server.name,
        icon_url: icon_url,
        invite_code: invite&.code,
        instance_url: instance_url
      }
    end

    render json: { servers: servers_data }
  end

  # GET /federation/profiles/:pubkey/friends
  def friends
    user = find_local_user
    return unless user

    protocol = Rails.env.development? ? "http" : "https"
    host = request.host_with_port

    friends_data = user.friends.includes(avatar_attachment: :blob).map do |friend|
      avatar_url = if friend.avatar.attached?
        rails_blob_url(friend.avatar, host: host, protocol: protocol)
      end

      {
        username: friend.username,
        display_name: friend.display_name,
        discriminator: friend.discriminator,
        avatar_url: avatar_url,
        profile_color: friend.profile_color,
        nostr_public_key: friend.nostr_public_key,
        online_state: friend.online_state
      }
    end

    render json: { friends: friends_data }
  end

  # GET /federation/profiles/:pubkey/folders
  def folders
    user = find_local_user
    return unless user

    folders_data = user.server_folders.ordered.includes(server_memberships: :server).map do |folder|
      server_ids = folder.server_memberships.ordered.map { |m| m.server.public_id }

      {
        name: folder.name,
        color: folder.color,
        position: folder.position,
        collapsed: folder.collapsed,
        server_ids: server_ids
      }
    end

    render json: { folders: folders_data }
  end

  # GET /federation/profiles/:pubkey/gif_collections
  def gif_collections
    user = find_local_user
    return unless user

    collections_data = user.gif_collections.ordered.includes(:gif_favorites).map do |collection|
      {
        name: collection.name,
        icon: collection.icon,
        position: collection.position,
        favorites: collection.gif_favorites.ordered.map do |fav|
          {
            tenor_gif_id: fav.tenor_gif_id,
            tenor_url: fav.tenor_url,
            preview_url: fav.preview_url,
            gif_url: fav.gif_url,
            description: fav.description,
            position: fav.position
          }
        end
      }
    end

    render json: { gif_collections: collections_data }
  end

  private

  def find_local_user
    user = User.local.find_by(nostr_public_key: params[:pubkey])
    render(json: { error: "User not found" }, status: :not_found) unless user
    user
  end

  def verify_federation_token
    token = request.headers["X-Federation-Token"]
    unless token.present?
      render json: { error: "Federation token required" }, status: :unauthorized
      return
    end

    payload = FederationTokenService.verify(token)
    unless payload
      render json: { error: "Invalid or expired federation token" }, status: :unauthorized
      return
    end

    # Token must match the requested pubkey
    unless payload["pubkey"] == params[:pubkey]
      render json: { error: "Token does not match requested user" }, status: :forbidden
      return
    end

    # Token must be from the requesting instance
    requesting = params[:requesting_instance]&.strip&.downcase
    if requesting.present? && payload["instance"] != requesting
      render json: { error: "Token instance mismatch" }, status: :forbidden
      return
    end

    # Auto-link relay for the requesting instance
    auto_link_relay_for(requesting) if requesting.present?
  end

  def auto_link_relay_for(domain)
    return if domain.blank?
    relay_url = domain.include?(":") ? "ws://#{domain}" : "wss://#{domain}"
    RelayConnection.find_or_create_for_relay(relay_url)
  rescue StandardError => e
    Rails.logger.warn("Failed to auto-link relay for #{domain}: #{e.message}")
  end

  def verify_federation_open
    if InstanceConfig.current.federation_closed?
      render json: { error: "Federation is closed" }, status: :forbidden
    end
  end

  def check_blocklist
    requesting = params[:requesting_instance]&.strip&.downcase
    if requesting.present? && InstanceBlocklist.blocked?(requesting)
      render json: { error: "Instance is blocked" }, status: :forbidden
    end
  end
end
