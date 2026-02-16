class Federation::FriendRequestsController < ApplicationController
  skip_before_action :verify_authenticity_token

  before_action :verify_federation_open
  before_action :check_blocklist, only: [:lookup, :create, :push_conversation_reference]

  # POST /federation/users/lookup
  # Look up a local user by username + discriminator
  def lookup
    user = User.local.find_by(
      username: params[:username],
      discriminator: params[:discriminator]
    )

    unless user
      render json: { error: "User not found" }, status: :not_found
      return
    end

    protocol = Rails.env.development? ? "http" : "https"
    host = request.host_with_port

    avatar_url = if user.avatar.attached?
      rails_blob_url(user.avatar, host: host, protocol: protocol)
    end

    render json: {
      pubkey: user.nostr_public_key,
      username: user.username,
      display_name: user.display_name,
      discriminator: user.discriminator,
      avatar_url: avatar_url,
      profile_color: user.profile_color
    }
  end

  # POST /federation/friend_requests
  # Receive a friend request from a remote instance
  def create
    event_data = params[:event]
    from_instance_url = params[:from_instance_url]
    callback_token = params[:callback_token]

    unless event_data.present? && from_instance_url.present? && callback_token.present?
      render json: { error: "Missing required parameters" }, status: :bad_request
      return
    end

    # Verify the Nostr event signature
    begin
      verify_friend_request_event(event_data)
    rescue NostrEventService::InvalidSignature, NostrEventService::InvalidEvent => e
      render json: { error: "Invalid event: #{e.message}" }, status: :unprocessable_entity
      return
    end

    content = JSON.parse(event_data[:content] || event_data["content"])
    to_username = content["to_username"]
    to_discriminator = content["to_discriminator"]
    from_pubkey = event_data[:pubkey] || event_data["pubkey"]

    # Find target local user
    target = User.local.find_by(username: to_username, discriminator: to_discriminator)
    unless target
      render json: { error: "User not found" }, status: :not_found
      return
    end

    # Create or find shadow user for the sender
    remote_user = RemoteUser.find_or_create_from_auth(
      public_key: from_pubkey,
      home_instance: extract_domain(from_instance_url),
      username: content["from_username"],
      display_name: content["from_display_name"],
      discriminator: content["from_discriminator"],
      avatar_url: content["from_avatar_url"],
      profile_color: content["from_profile_color"]
    )
    shadow_sender = remote_user.shadow_user

    # Check user-level blocks
    if Block.exists?(blocker_id: target.id, blocked_id: shadow_sender.id)
      render json: { error: "User has blocked this contact" }, status: :forbidden
      return
    end

    if Block.exists?(blocker_id: shadow_sender.id, blocked_id: target.id)
      render json: { error: "Sender has blocked this user" }, status: :forbidden
      return
    end

    # Check existing friendship
    existing = Friendship.find_by(user: shadow_sender, friend: target)
    if existing
      render json: { error: "Friendship already exists" }, status: :conflict
      return
    end

    # Create the friendship
    friendship = Friendship.new(
      user: shadow_sender,
      friend: target,
      status: :pending,
      federation_callback_token: callback_token
    )

    unless friendship.save
      render json: { error: friendship.errors.full_messages.join(", ") }, status: :unprocessable_entity
      return
    end

    # Notify target via ActionCable
    ActionCable.server.broadcast("user_notifications_#{target.id}", {
      type: "friend_request",
      from_user: shadow_sender.display_name.presence || shadow_sender.username,
      from_user_id: shadow_sender.public_id
    })

    render json: {
      status: "sent",
      to_user: {
        pubkey: target.nostr_public_key,
        display_name: target.display_name,
        avatar_url: nil,
        profile_color: target.profile_color
      }
    }
  end

  # POST /federation/friend_requests/respond
  # Receive acceptance/decline callback from remote instance
  def respond
    callback_token = params[:callback_token]
    status = params[:status]

    unless callback_token.present? && status.present?
      render json: { error: "Missing required parameters" }, status: :bad_request
      return
    end

    payload = FederationCallbackTokenService.verify(callback_token)
    unless payload
      render json: { error: "Invalid or expired callback token" }, status: :unauthorized
      return
    end

    # Find the pending friendship by the pubkeys from the token
    from_user = User.find_by(nostr_public_key: payload[:from_pubkey]) ||
                User.joins(:remote_user_detail).where(remote_users: { nostr_public_key: payload[:from_pubkey] }).first
    to_remote = RemoteUser.find_by(nostr_public_key: payload[:to_pubkey])
    to_shadow = to_remote&.shadow_user

    unless from_user && to_shadow
      render json: { error: "Users not found for this token" }, status: :not_found
      return
    end

    friendship = Friendship.find_by(user: from_user, friend: to_shadow, status: :pending)
    unless friendship
      render json: { error: "No pending friendship found" }, status: :not_found
      return
    end

    if status == "accepted"
      friendship.accept!

      # Create conversation on this instance
      conversation = Conversation.find_or_create_direct(from_user, to_shadow)

      # Update responder profile on shadow user
      if params[:responder_username].present?
        to_remote.update(
          username: params[:responder_username],
          display_name: params[:responder_display_name],
          avatar_url: params[:responder_avatar_url],
          profile_color: params[:responder_profile_color],
          discriminator: params[:responder_discriminator]
        )
        to_shadow.update(
          display_name: params[:responder_display_name].presence || to_shadow.display_name
        )
      end

      # Push conversation reference to the responder's home instance
      if to_remote.home_instance.present?
        protocol = Rails.env.development? ? "http" : "https"
        FederationService.push_conversation_reference(
          instance_url: "#{protocol}://#{to_remote.home_instance}",
          for_pubkey: payload[:to_pubkey],
          conversation_id: conversation.public_id,
          other_user: from_user
        )
      end
    elsif status == "declined"
      friendship.update!(status: :declined)
    end

    render json: { status: "ok" }
  end

  # POST /federation/conversations/push_reference
  # Receive a conversation reference from a remote instance
  def push_conversation_reference
    for_pubkey = params[:for_pubkey]
    conversation_id = params[:conversation_id]
    instance_url = params[:instance_url]

    unless for_pubkey.present? && conversation_id.present? && instance_url.present?
      render json: { error: "Missing required parameters" }, status: :bad_request
      return
    end

    # Find the local user (or shadow user) by pubkey
    user = User.find_by(nostr_public_key: for_pubkey) ||
           User.joins(:remote_user_detail).where(remote_users: { nostr_public_key: for_pubkey }).first

    unless user
      render json: { error: "User not found" }, status: :not_found
      return
    end

    ref = user.remote_conversation_references.find_or_initialize_by(
      remote_instance_url: instance_url,
      remote_conversation_id: conversation_id
    )
    ref.update!(
      kind: "direct",
      other_username: params[:other_username],
      other_display_name: params[:other_display_name],
      other_avatar_url: params[:other_avatar_url],
      other_profile_color: params[:other_profile_color]
    )

    render json: { status: "ok" }
  end

  private

  def verify_friend_request_event(event_data)
    event = event_data.respond_to?(:to_unsafe_h) ? event_data.to_unsafe_h.deep_stringify_keys : event_data.deep_stringify_keys

    raise NostrEventService::InvalidEvent, "Missing pubkey" if event["pubkey"].blank?
    raise NostrEventService::InvalidEvent, "Missing signature" if event["sig"].blank?
    raise NostrEventService::InvalidEvent, "Missing event id" if event["id"].blank?
    raise NostrEventService::InvalidEvent, "Wrong event kind" unless event["kind"] == 30078

    # Verify event ID
    serialized = [
      0,
      event["pubkey"],
      event["created_at"],
      event["kind"],
      event["tags"] || [],
      event["content"] || ""
    ]
    expected_id = Digest::SHA256.hexdigest(JSON.generate(serialized))
    raise NostrEventService::InvalidEvent, "Event ID mismatch" unless event["id"] == expected_id

    # Verify Schnorr signature
    NostrEventService.verify_schnorr_signature(
      message_hex: event["id"],
      pubkey_hex: event["pubkey"],
      signature_hex: event["sig"]
    )
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

  def verify_federation_open
    if InstanceConfig.current.federation_closed?
      render json: { error: "Federation is closed" }, status: :forbidden
    end
  end

  def check_blocklist
    requesting = params[:requesting_instance]&.strip&.downcase
    # Also check from_instance_url for friend requests
    requesting ||= extract_domain(params[:from_instance_url]).downcase if params[:from_instance_url].present?
    if requesting.present? && InstanceBlocklist.blocked?(requesting)
      render json: { error: "Communications with that instance are restricted" }, status: :forbidden
    end
  end
end
