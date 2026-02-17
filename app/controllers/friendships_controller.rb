class FriendshipsController < ApplicationController
  before_action :authenticate_user!

  def index
    redirect_to conversations_path(tab: "online")
  end

  def create
    instance_url = params[:instance_url].to_s.strip.presence

    # Cross-instance friend request
    if instance_url.present?
      create_remote_friend_request(instance_url)
      return
    end

    # Local friend request
    tag = params[:tag].to_s.strip
    if tag.include?("#")
      username, discriminator = tag.split("#", 2)
      friend = User.find_by(username: username, discriminator: discriminator)
    else
      friend = User.find_by(public_id: params[:user_id])
    end

    if friend.nil?
      redirect_to conversations_path(tab: "add_friend"), alert: "User not found. Make sure the username and tag are correct."
      return
    end

    if friend == current_user
      redirect_to conversations_path(tab: "add_friend"), alert: "You can't add yourself."
      return
    end

    friendship = current_user.friendships.new(friend: friend, status: :pending)
    if friendship.save
      ActionCable.server.broadcast("user_notifications_#{friend.id}", {
        type: "friend_request",
        from_user: current_user.display_name.presence || current_user.username,
        from_user_id: current_user.public_id
      })
      redirect_to conversations_path(tab: "pending"), notice: "Friend request sent to #{friend.tag}!"
    else
      redirect_to conversations_path(tab: "add_friend"), alert: friendship.errors.full_messages.join(", ")
    end
  end

  def accept
    friendship = Friendship.find(params[:id])
    if friendship.friend == current_user
      friendship.accept!
      redirect_to conversations_path(tab: "all"), notice: "Friend request accepted!"
    else
      redirect_to conversations_path(tab: "pending"), alert: "Not authorized"
    end
  end

  def decline
    friendship = Friendship.find(params[:id])
    if friendship.friend == current_user
      friendship.update!(status: :declined)
      redirect_to conversations_path(tab: "pending"), notice: "Friend request declined."
    else
      redirect_to conversations_path(tab: "pending"), alert: "Not authorized"
    end
  end

  def destroy
    friendship = current_user.friendships.find(params[:id])
    friend = friendship.friend
    Friendship.where(user_id: current_user.id, friend_id: friend.id).destroy_all
    Friendship.where(user_id: friend.id, friend_id: current_user.id).destroy_all
    redirect_to conversations_path(tab: "all"), notice: "Removed #{friend.tag} from friends."
  end

  private

  def create_remote_friend_request(instance_url)
    tag = params[:tag].to_s.strip
    unless tag.include?("#")
      redirect_to conversations_path(tab: "add_friend"), alert: "Enter a full tag like Username#0000 for cross-instance requests."
      return
    end

    username, discriminator = tag.split("#", 2)

    # Normalize instance URL
    instance_url = "#{Rails.env.development? ? 'http' : 'https'}://#{instance_url}" unless instance_url.start_with?("http")
    instance_url = instance_url.chomp("/")

    # Check local blocklist
    domain = extract_domain(instance_url)
    if InstanceBlocklist.blocked?(domain)
      redirect_to conversations_path(tab: "add_friend"), alert: "Communications with that instance are restricted."
      return
    end

    # Check the user has a Nostr keypair
    unless current_user.nostr_private_key.present?
      redirect_to conversations_path(tab: "add_friend"), alert: "You need a Nostr keypair to send cross-instance friend requests."
      return
    end

    # Look up the remote user
    begin
      profile = FederationService.lookup_remote_user(
        instance_url: instance_url,
        username: username,
        discriminator: discriminator
      )
    rescue FederationService::FederationError => e
      redirect_to conversations_path(tab: "add_friend"), alert: e.message
      return
    end

    # Create shadow user for the remote friend on this instance
    remote_user = RemoteUser.find_or_create_from_auth(
      public_key: profile["pubkey"],
      home_instance: domain,
      username: profile["username"],
      display_name: profile["display_name"],
      discriminator: profile["discriminator"],
      avatar_url: profile["avatar_url"],
      profile_color: profile["profile_color"]
    )
    shadow_friend = remote_user.shadow_user

    # Check blocks
    if current_user.blocked?(shadow_friend)
      redirect_to conversations_path(tab: "add_friend"), alert: "You have blocked this user."
      return
    end

    if shadow_friend.blocked?(current_user)
      redirect_to conversations_path(tab: "add_friend"), alert: "This user has blocked you."
      return
    end

    # Check existing friendship
    existing = Friendship.find_by(user: current_user, friend: shadow_friend)
    if existing
      redirect_to conversations_path(tab: "add_friend"), alert: "You already have a #{existing.status} friendship with this user."
      return
    end

    # Generate callback token
    callback_token = FederationCallbackTokenService.generate(
      from_pubkey: current_user.nostr_public_key,
      to_pubkey: profile["pubkey"]
    )

    # Create local pending friendship
    friendship = current_user.friendships.new(
      friend: shadow_friend,
      status: :pending,
      federation_callback_token: callback_token
    )

    unless friendship.save
      redirect_to conversations_path(tab: "add_friend"), alert: friendship.errors.full_messages.join(", ")
      return
    end

    # Send the friend request to the remote instance
    begin
      FederationService.send_remote_friend_request(
        from_user: current_user,
        instance_url: instance_url,
        to_username: username,
        to_discriminator: discriminator,
        callback_token: callback_token
      )
    rescue FederationService::FederationError => e
      # Clean up local friendship on remote failure
      friendship.destroy
      redirect_to conversations_path(tab: "add_friend"), alert: e.message
      return
    end

    redirect_to conversations_path(tab: "pending"), notice: "Friend request sent to #{tag} on #{domain}!"
  end

  def extract_domain(url)
    uri = URI.parse(url)
    port = uri.port
    default_port = uri.scheme == "https" ? 443 : 80
    if port && port != default_port
      "#{uri.host}:#{port}"
    else
      uri.host
    end
  rescue URI::InvalidURIError
    url
  end
end
