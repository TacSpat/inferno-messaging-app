class Api::FederationSyncController < ApplicationController
  before_action :authenticate_user!

  # POST /api/federation_sync
  # Re-syncs data from a remote instance (or home instance for shadow users)
  def create
    unless current_user.remote? && current_user.remote_user_detail.present?
      render json: { status: "skipped", message: "Not a remote user" }
      return
    end

    remote_user = current_user.remote_user_detail
    home = remote_user.home_instance
    pubkey = remote_user.nostr_public_key
    token = remote_user.federation_token

    synced = []

    # Profile
    profile_data = FederationService.fetch_remote_profile(home_instance: home, pubkey: pubkey, token: token)
    if profile_data
      remote_user.sync_from_profile_data(profile_data)
      synced << "profile"
    end

    # Servers
    servers_data = FederationService.fetch_remote_servers(home_instance: home, pubkey: pubkey, token: token)
    if servers_data
      sync_server_references(current_user, servers_data)
      synced << "servers"
    end

    # Friends
    friends_data = FederationService.fetch_remote_friends(home_instance: home, pubkey: pubkey, token: token)
    if friends_data
      sync_friend_references(current_user, home, friends_data)
      synced << "friends"
    end

    # Conversations
    conversations_data = FederationService.fetch_remote_conversations(home_instance: home, pubkey: pubkey, token: token)
    if conversations_data
      sync_conversation_references(current_user, conversations_data)
      synced << "conversations"
    end

    # GIF collections
    gif_data = FederationService.fetch_remote_gif_collections(home_instance: home, pubkey: pubkey, token: token)
    if gif_data
      sync_gif_collections(current_user, gif_data)
      synced << "gif_collections"
    end

    render json: { status: "ok", synced: synced }
  end

  # GET /api/federation_sync/check_reachable?url=...
  # Checks if the current user's account still exists on the remote instance
  # by hitting the federation profile endpoint. If not, prunes the matching reference.
  def check_reachable
    url = params[:url].to_s
    if url.blank? || !current_user.remote?
      render json: { reachable: false }
      return
    end

    remote_user = current_user.remote_user_detail
    unless remote_user
      render json: { reachable: false }
      return
    end

    # Check if the user's profile still exists on their home instance
    profile = FederationService.fetch_remote_profile(
      home_instance: remote_user.home_instance,
      pubkey: remote_user.nostr_public_key,
      token: remote_user.federation_token
    )

    if profile
      render json: { reachable: true }
    else
      # Profile gone — prune the matching reference
      current_user.remote_server_references.each do |ref|
        if (ref.remote_server_url || ref.remote_instance_url) == url
          ref.destroy
          break
        end
      end
      current_user.remote_conversation_references.each do |ref|
        if ref.remote_conversation_url == url
          ref.destroy
          break
        end
      end

      render json: { reachable: false }
    end
  end

  private

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
