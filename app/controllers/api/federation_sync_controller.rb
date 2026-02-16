class Api::FederationSyncController < ApplicationController
  before_action :authenticate_user!

  # POST /api/federation_sync
  # For remote (shadow) users: re-syncs data from home instance.
  # For local users: checks if their account still exists on the target remote instance.
  def create
    if current_user.remote? && current_user.remote_user_detail.present?
      sync_remote_user
    else
      check_local_user_remote_access
    end
  end

  private

  def sync_remote_user
    remote_user = current_user.remote_user_detail
    home = remote_user.home_instance
    pubkey = remote_user.nostr_public_key
    token = remote_user.federation_token

    synced = []

    profile_data = FederationService.fetch_remote_profile(home_instance: home, pubkey: pubkey, token: token)
    if profile_data
      remote_user.sync_from_profile_data(profile_data)
      synced << "profile"
    end

    servers_data = FederationService.fetch_remote_servers(home_instance: home, pubkey: pubkey, token: token)
    if servers_data
      sync_server_references(current_user, servers_data)
      synced << "servers"
    end

    friends_data = FederationService.fetch_remote_friends(home_instance: home, pubkey: pubkey, token: token)
    if friends_data
      sync_friend_references(current_user, home, friends_data)
      synced << "friends"
    end

    conversations_data = FederationService.fetch_remote_conversations(home_instance: home, pubkey: pubkey, token: token)
    if conversations_data
      sync_conversation_references(current_user, conversations_data)
      synced << "conversations"
    end

    gif_data = FederationService.fetch_remote_gif_collections(home_instance: home, pubkey: pubkey, token: token)
    if gif_data
      sync_gif_collections(current_user, gif_data)
      synced << "gif_collections"
    end

    unless synced.include?("profile")
      current_user.remote_server_references.destroy_all
      current_user.remote_conversation_references.destroy_all
      render json: { status: "home_unreachable", synced: synced }
      return
    end

    render json: { status: "ok", synced: synced }
  end

  # For local users clicking a remote server/conversation link.
  # Extract the instance from the target URL and check if the user's
  # shadow account still exists there via the federation profile endpoint.
  def check_local_user_remote_access
    target_url = params[:target_url].to_s
    if target_url.blank? || !current_user.nostr_public_key.present?
      render json: { status: "ok", synced: [] }
      return
    end

    # Extract instance host from target URL
    uri = URI.parse(target_url) rescue nil
    unless uri&.host
      render json: { status: "ok", synced: [] }
      return
    end

    instance_host = uri.host
    instance_host += ":#{uri.port}" if uri.port && ![80, 443].include?(uri.port)

    # Check if the remote instance still knows about this user
    profile = FederationService.fetch_remote_profile(
      home_instance: instance_host,
      pubkey: current_user.nostr_public_key
    )

    if profile
      render json: { status: "ok", synced: [] }
    else
      # Shadow account was deleted on the remote — prune references for that instance
      protocol = Rails.env.development? ? "http" : "https"
      instance_url = "#{protocol}://#{instance_host}"

      current_user.remote_server_references
        .where(remote_instance_url: instance_url)
        .destroy_all
      current_user.remote_conversation_references
        .where(remote_instance_url: instance_url)
        .destroy_all

      render json: { status: "home_unreachable", synced: [] }
    end
  end

  def sync_server_references(user, data)
    (data["servers"] || []).each do |server_data|
      ref = user.remote_server_references.find_or_initialize_by(
        remote_instance_url: server_data["instance_url"],
        remote_server_id: server_data["server_id"]
      )
      ref.update!(
        name: server_data["name"],
        icon_url: server_data["icon_url"],
        invite_code: server_data["invite_code"]
      )
    end
  end

  def sync_friend_references(user, home_instance, data)
    friends = data["friends"] || []
    synced_ids = []
    protocol = Rails.env.development? ? "http" : "https"
    home_url = "#{protocol}://#{home_instance}"

    friends.each do |friend_data|
      ref = user.remote_friend_references.find_or_initialize_by(
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

    user.remote_friend_references
      .where.not(id: synced_ids)
      .destroy_all
  end

  def sync_conversation_references(user, data)
    (data["conversations"] || []).each do |conv_data|
      other = conv_data["other_user"] || {}
      ref = user.remote_conversation_references.find_or_initialize_by(
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
    end
  end

  def sync_gif_collections(user, data)
    (data["gif_collections"] || []).each do |coll_data|
      collection = user.gif_collections.find_or_initialize_by(name: coll_data["name"])
      collection.icon = coll_data["icon"]
      collection.position = coll_data["position"] || 0
      collection.save!

      (coll_data["favorites"] || []).each do |fav_data|
        fav = user.gif_favorites.find_or_initialize_by(
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

end
