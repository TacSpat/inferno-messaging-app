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

    folders_data = FederationService.fetch_remote_folders(home_instance: home, pubkey: pubkey, token: token)
    if folders_data
      sync_folders(current_user, folders_data)
      synced << "folders"
    end

    gif_data = FederationService.fetch_remote_gif_collections(home_instance: home, pubkey: pubkey, token: token)
    if gif_data
      sync_gif_collections(current_user, gif_data)
      synced << "gif_collections"
    end

    unless synced.include?("profile")
      current_user.remote_server_references.destroy_all
      current_user.remote_conversation_references.destroy_all
      current_user.server_folders.destroy_all
      render json: { status: "home_unreachable", synced: synced }
      return
    end

    render json: { status: "ok", synced: synced }
  end

  # For local users: pull fresh server memberships from the target remote instance.
  def check_local_user_remote_access
    target_url = params[:target_url].to_s
    pubkey = current_user.nostr_public_key

    if target_url.blank? || pubkey.blank?
      render json: { status: "skipped", synced: [] }
      return
    end

    # Extract instance host from target URL
    uri = URI.parse(target_url) rescue nil
    unless uri&.host
      render json: { status: "ok", synced: [] }
      return
    end

    instance_host = uri.host
    instance_host += ":#{uri.port}" if uri.port && ![ 80, 443 ].include?(uri.port)

    # Pull current memberships from the remote instance
    data = FederationService.fetch_remote_memberships(instance: instance_host, pubkey: pubkey)

    if data
      sync_server_references(current_user, data)
      render json: { status: "ok", synced: [ "servers" ] }
    else
      # Remote instance unreachable or user not found there
      render json: { status: "ok", synced: [] }
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
    protocol = home_instance.to_s.include?(":") ? "http" : "https"
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

  def sync_folders(user, data)
    folders = data["folders"] || []
    synced_folder_ids = []

    # Build a lookup from home server_id → local remote_server_reference
    remote_ref_lookup = user.remote_server_references.index_by(&:remote_server_id)

    folders.each do |folder_data|
      folder = user.server_folders.find_or_initialize_by(name: folder_data["name"])
      folder.assign_attributes(
        color: folder_data["color"] || "#4f545c",
        position: folder_data["position"] || 0,
        collapsed: folder_data["collapsed"] != false
      )
      folder.save!
      synced_folder_ids << folder.id

      # Assign remote server references to this folder based on server_ids from home
      home_server_ids = folder_data["server_ids"] || []
      home_server_ids.each_with_index do |server_id, idx|
        ref = remote_ref_lookup[server_id]
        next unless ref
        ref.update_columns(server_folder_id: folder.id, position: idx)
      end
    end

    # Remove folders that no longer exist on home (move their refs back to top-level)
    stale_folders = user.server_folders.where.not(id: synced_folder_ids)
    stale_folders.each do |folder|
      folder.remote_server_references.update_all(server_folder_id: nil)
    end
    stale_folders.destroy_all

    # Ensure remote refs not in any folder are top-level
    user.remote_server_references
      .where.not(server_folder_id: synced_folder_ids)
      .where.not(server_folder_id: nil)
      .update_all(server_folder_id: nil)
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
