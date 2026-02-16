class Federation::ServersController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_federation_open

  # POST /federation/create_server
  # Accepts a signed Nostr kind 30078 event with server creation details
  def create
    event_json = params[:event]
    unless event_json.present?
      return render json: { error: "Missing signed event" }, status: :bad_request
    end

    event_data = parse_and_verify_event(event_json)
    unless event_data
      return # response already rendered
    end

    pubkey = event_data["pubkey"]

    # Check blocklist
    home_instance = extract_home_instance(event_data)
    if home_instance && InstanceBlocklist.blocked?(home_instance)
      return render json: { error: "Instance is blocked" }, status: :forbidden
    end

    # Find or create the remote user
    content = JSON.parse(event_data["content"]) rescue {}
    remote_user = RemoteUser.find_or_create_from_auth(
      public_key: pubkey,
      home_instance: home_instance || "unknown",
      username: content["username"].presence || "remote_#{pubkey[0..7]}"
    )
    shadow_user = remote_user.reload.shadow_user

    # Create the server
    server = Server.new(
      name: content["name"].presence || "New Server",
      description: content["description"]
    )
    server.owner = shadow_user

    unless server.save
      return render json: { error: "Failed to create server", details: server.errors.full_messages }, status: :unprocessable_entity
    end

    # Generate an invite code
    invite = server.invites.create!(
      creator: shadow_user,
      max_uses: 0,
      expires_at: nil
    )

    render json: {
      server_id: server.public_id,
      invite_code: invite.code,
      server_name: server.name,
      instance_domain: Rails.application.config.x.instance_domain
    }, status: :created
  end

  private

  def verify_federation_open
    config = InstanceConfig.current
    if config.federation_closed? || config.remote_joins_blocked?
      render json: { error: "Federation is closed" }, status: :forbidden
    end
  end

  def parse_and_verify_event(event_json)
    event_data = case event_json
    when String then JSON.parse(event_json)
    when ActionController::Parameters then event_json.to_unsafe_h.deep_stringify_keys
    when Hash then event_json.deep_stringify_keys
    else event_json
    end

    # Kind 30078 — parameterized replaceable event
    unless event_data["kind"] == 30078
      render json: { error: "Invalid event kind, expected 30078" }, status: :bad_request
      return nil
    end

    # Verify d-tag
    d_tag = (event_data["tags"] || []).find { |t| t[0] == "d" }
    unless d_tag && d_tag[1] == "create_server"
      render json: { error: "Missing or invalid d-tag" }, status: :bad_request
      return nil
    end

    # Verify required fields
    unless event_data["pubkey"].present? && event_data["sig"].present? && event_data["id"].present?
      render json: { error: "Missing required event fields" }, status: :bad_request
      return nil
    end

    # Verify event ID
    serialized = [
      0,
      event_data["pubkey"],
      event_data["created_at"],
      event_data["kind"],
      event_data["tags"] || [],
      event_data["content"] || ""
    ]
    expected_id = Digest::SHA256.hexdigest(JSON.generate(serialized))
    unless event_data["id"] == expected_id
      render json: { error: "Event ID mismatch" }, status: :bad_request
      return nil
    end

    # Verify Schnorr signature
    begin
      NostrEventService.verify_schnorr_signature(
        message_hex: event_data["id"],
        pubkey_hex: event_data["pubkey"],
        signature_hex: event_data["sig"]
      )
    rescue NostrEventService::InvalidSignature => e
      render json: { error: "Invalid signature: #{e.message}" }, status: :unauthorized
      return nil
    end

    # Check event is recent
    event_time = Time.at(event_data["created_at"])
    if event_time < 10.minutes.ago || event_time > 1.minute.from_now
      render json: { error: "Event timestamp out of range" }, status: :bad_request
      return nil
    end

    event_data
  end

  def extract_home_instance(event_data)
    relay_tag = (event_data["tags"] || []).find { |t| t[0] == "relay" }
    return nil unless relay_tag

    uri = URI.parse(relay_tag[1])
    uri.host
  rescue URI::InvalidURIError
    nil
  end
end
