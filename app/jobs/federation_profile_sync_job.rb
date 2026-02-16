class FederationProfileSyncJob < ApplicationJob
  queue_as :default

  def perform(remote_user_id)
    remote_user = RemoteUser.find_by(id: remote_user_id)
    return unless remote_user

    shadow_user = remote_user.shadow_user
    return unless shadow_user

    home = remote_user.home_instance
    pubkey = remote_user.nostr_public_key
    token = remote_user.federation_token

    # Sync profile data
    profile_data = FederationService.fetch_remote_profile(home_instance: home, pubkey: pubkey, token: token)
    if profile_data
      remote_user.sync_from_profile_data(profile_data)
    else
      # Profile not found (user may have been deleted on home instance)
      Rails.logger.info("Federation: profile not found for #{pubkey} on #{home}, user may have been deleted")
    end

    # Sync server references
    servers_data = FederationService.fetch_remote_servers(home_instance: home, pubkey: pubkey, token: token)
    sync_server_references(shadow_user, servers_data) if servers_data

    # Sync conversation references
    conversations_data = FederationService.fetch_remote_conversations(home_instance: home, pubkey: pubkey, token: token)
    sync_conversation_references(shadow_user, conversations_data) if conversations_data

    # Sync friends
    friends_data = FederationService.fetch_remote_friends(home_instance: home, pubkey: pubkey, token: token)
    sync_friend_references(shadow_user, friends_data) if friends_data

    # Sync GIF collections
    gif_data = FederationService.fetch_remote_gif_collections(home_instance: home, pubkey: pubkey, token: token)
    sync_gif_collections(shadow_user, gif_data) if gif_data

    # Report this instance's server memberships back to home
    report_memberships_to_home(shadow_user, home, pubkey, token)
  end

  private

  def sync_server_references(shadow_user, data)
    servers = data["servers"] || []
    synced_ids = []

    servers.each do |server_data|
      ref = shadow_user.remote_server_references.find_or_initialize_by(
        remote_instance_url: server_data["instance_url"],
        remote_server_id: server_data["server_id"]
      )
      ref.update!(
        name: server_data["name"],
        icon_url: server_data["icon_url"],
        invite_code: server_data["invite_code"]
      )
      synced_ids << ref.id
    end

    # Remove references from home instance that no longer exist
    home_url_pattern = servers.first&.dig("instance_url")
    if home_url_pattern.present?
      shadow_user.remote_server_references
        .where(remote_instance_url: home_url_pattern)
        .where.not(id: synced_ids)
        .destroy_all
    end
  end

  def sync_friend_references(shadow_user, data)
    friends = data["friends"] || []
    synced_ids = []
    protocol = Rails.env.development? ? "http" : "https"
    home_url = "#{protocol}://#{shadow_user.remote_user_detail&.home_instance}"

    friends.each do |friend_data|
      ref = shadow_user.remote_friend_references.find_or_initialize_by(
        remote_instance_url: home_url,
        friend_public_key: friend_data["nostr_public_key"]
      )
      ref.update!(
        friend_username: friend_data["username"],
        friend_display_name: friend_data["display_name"],
        friend_discriminator: friend_data["discriminator"],
        friend_avatar_url: friend_data["avatar_url"],
        friend_profile_color: friend_data["profile_color"],
        online_state: friend_data["online_state"] || "offline"
      )
      synced_ids << ref.id
    end

    # Remove stale friend references
    shadow_user.remote_friend_references
      .where.not(id: synced_ids)
      .destroy_all
  end

  def sync_gif_collections(shadow_user, data)
    collections = data["gif_collections"] || []
    collections.each do |coll_data|
      collection = shadow_user.gif_collections.find_or_initialize_by(name: coll_data["name"])
      collection.icon = coll_data["icon"]
      collection.position = coll_data["position"] || 0
      collection.save!

      favorites = coll_data["favorites"] || []
      favorites.each do |fav_data|
        fav = shadow_user.gif_favorites.find_or_initialize_by(
          gif_collection: collection,
          tenor_gif_id: fav_data["tenor_gif_id"]
        )
        fav.assign_attributes(
          tenor_url: fav_data["tenor_url"],
          preview_url: fav_data["preview_url"],
          gif_url: fav_data["gif_url"],
          description: fav_data["description"],
          position: fav_data["position"] || 0
        )
        fav.save!
      end
    end
  end

  def report_memberships_to_home(shadow_user, home, pubkey, token)
    protocol = Rails.env.development? ? "http" : "https"
    instance_url = "#{protocol}://#{Rails.application.config.x.instance_domain}"

    # Gather this instance's local server memberships for the shadow user
    local_servers = shadow_user.server_memberships.includes(server: [:invites, { icon_attachment: :blob }]).map do |membership|
      server = membership.server
      invite = server.invites.first
      {
        server_id: server.public_id,
        name: server.name,
        icon_url: nil,
        invite_code: invite&.code,
        instance_url: instance_url
      }
    end

    return if local_servers.empty?

    FederationService.report_memberships_to_home(
      home_instance: home, pubkey: pubkey, token: token, servers: local_servers
    )
  end

  def sync_conversation_references(shadow_user, data)
    conversations = data["conversations"] || []
    synced_ids = []

    conversations.each do |conv_data|
      other = conv_data["other_user"] || {}
      ref = shadow_user.remote_conversation_references.find_or_initialize_by(
        remote_instance_url: conv_data["instance_url"],
        remote_conversation_id: conv_data["conversation_id"]
      )
      ref.update!(
        kind: conv_data["kind"],
        name: conv_data["name"],
        other_username: other["username"],
        other_display_name: other["display_name"],
        other_avatar_url: other["avatar_url"],
        other_profile_color: other["profile_color"],
        last_message_at: conv_data["last_message_at"]
      )
      synced_ids << ref.id
    end

    # Remove conversations from home instance that no longer exist
    home_url_pattern = conversations.first&.dig("instance_url")
    if home_url_pattern.present?
      shadow_user.remote_conversation_references
        .where(remote_instance_url: home_url_pattern)
        .where.not(id: synced_ids)
        .destroy_all
    end
  end

end
