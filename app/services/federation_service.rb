class FederationService
  class FederationError < StandardError; end

  # Create a server on a remote instance by sending a signed Nostr event
  def self.create_remote_server(user:, instance_url:, name:, description: nil)
    raise FederationError, "User has no Nostr keypair" unless user.nostr_private_key.present?

    # Normalize instance URL
    instance_url = "https://#{instance_url}" unless instance_url.start_with?("http")
    instance_url = instance_url.chomp("/")

    # Build the signed event
    event = build_create_server_event(user: user, instance_url: instance_url, name: name, description: description)

    # POST to remote instance
    uri = URI.parse("#{instance_url}/federation/create_server")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/json"
    request.body = { event: event }.to_json

    response = http.request(request)

    unless response.code.to_i == 201
      error_body = JSON.parse(response.body) rescue { "error" => response.body }
      raise FederationError, "Remote instance returned #{response.code}: #{error_body['error']}"
    end

    result = JSON.parse(response.body)

    # Store a local reference
    ref = RemoteServerReference.find_or_initialize_by(
      user: user,
      remote_instance_url: instance_url,
      remote_server_id: result["server_id"]
    )
    ref.update!(
      name: result["server_name"],
      invite_code: result["invite_code"]
    )

    ref
  end

  # Fetch a user's profile from their home instance
  def self.fetch_remote_profile(home_instance:, pubkey:, token: nil)
    fetch_federation_json(home_instance, "/federation/profiles/#{pubkey}", token: token)
  end

  # Fetch a user's server list from their home instance
  def self.fetch_remote_servers(home_instance:, pubkey:, token: nil)
    fetch_federation_json(home_instance, "/federation/profiles/#{pubkey}/servers", token: token)
  end

  # Fetch a user's conversation list from their home instance
  def self.fetch_remote_conversations(home_instance:, pubkey:, token: nil)
    fetch_federation_json(home_instance, "/federation/profiles/#{pubkey}/conversations", token: token)
  end

  # Fetch a user's friends list from their home instance
  def self.fetch_remote_friends(home_instance:, pubkey:, token: nil)
    fetch_federation_json(home_instance, "/federation/profiles/#{pubkey}/friends", token: token)
  end

  # Fetch a user's GIF collections from their home instance
  def self.fetch_remote_gif_collections(home_instance:, pubkey:, token: nil)
    fetch_federation_json(home_instance, "/federation/profiles/#{pubkey}/gif_collections", token: token)
  end

  # Report this instance's server memberships back to the user's home instance
  def self.report_memberships_to_home(home_instance:, pubkey:, token: nil, servers:)
    post_federation_json(home_instance, "/federation/profiles/#{pubkey}/report_memberships", token: token, body: { servers: servers })
  end

  # Look up a user on a remote instance by username#discriminator
  def self.lookup_remote_user(instance_url:, username:, discriminator:)
    instance_url = normalize_instance_url(instance_url)
    requesting_instance = Rails.application.config.x.instance_domain

    result = post_federation_json_raw(
      instance_url,
      "/federation/users/lookup",
      body: { username: username, discriminator: discriminator, requesting_instance: requesting_instance }
    )

    case result[:status]
    when 200
      result[:body]
    when 403
      raise FederationError, result.dig(:body, "error") || "Communications with that instance are restricted"
    when 404
      raise FederationError, "User not found on that instance"
    else
      raise FederationError, result.dig(:body, "error") || "Could not reach that instance"
    end
  end

  # Send a friend request to a remote instance
  def self.send_remote_friend_request(from_user:, instance_url:, to_username:, to_discriminator:, callback_token:)
    instance_url = normalize_instance_url(instance_url)
    raise FederationError, "User has no Nostr keypair" unless from_user.nostr_private_key.present?

    event = build_friend_request_event(
      user: from_user,
      to_username: to_username,
      to_discriminator: to_discriminator
    )

    result = post_federation_json_raw(
      instance_url,
      "/federation/friend_requests",
      body: {
        event: event,
        from_instance_url: federation_instance_url,
        callback_token: callback_token
      }
    )

    case result[:status]
    when 200, 201
      result[:body]
    when 403
      raise FederationError, result.dig(:body, "error") || "Communications with that instance are restricted"
    when 404
      raise FederationError, "User not found on that instance"
    when 409
      raise FederationError, result.dig(:body, "error") || "Friendship already exists"
    else
      raise FederationError, result.dig(:body, "error") || "Could not reach that instance"
    end
  end

  # Notify a remote instance of a friend request response (accept/decline)
  def self.notify_friend_response(instance_url:, callback_token:, status:, responder:)
    instance_url = normalize_instance_url(instance_url)
    uri = URI.parse(instance_url)
    host_with_port = uri.host
    port = uri.port
    default_port = uri.scheme == "https" ? 443 : 80
    host_with_port += ":#{port}" if port && port != default_port

    protocol = Rails.env.development? ? "http" : "https"
    avatar_url = if responder.avatar.attached?
      Rails.application.routes.url_helpers.rails_blob_url(
        responder.avatar, host: Rails.application.config.x.instance_domain, protocol: protocol
      )
    end

    post_federation_json(
      host_with_port,
      "/federation/friend_requests/respond",
      body: {
        callback_token: callback_token,
        status: status,
        responder_pubkey: responder.nostr_public_key,
        responder_username: responder.username,
        responder_display_name: responder.display_name,
        responder_discriminator: responder.discriminator,
        responder_avatar_url: avatar_url,
        responder_profile_color: responder.profile_color
      }
    )
  end

  # Quick reachability check — GET request with short timeout.
  # Returns true if the URL responds with a 2xx status.
  # Returns false if unreachable, 4xx/5xx, or redirects to a login page
  # (meaning the user's shadow account was deleted on that instance).
  def self.reachable?(url)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 3
    http.read_timeout = 3

    request = Net::HTTP::Get.new(uri.request_uri)
    response = http.request(request)
    code = response.code.to_i

    return true if code >= 200 && code < 300

    # Redirect to login means user no longer exists there
    if code >= 300 && code < 400
      location = response["Location"].to_s
      return false if location.match?(/sign_in|login|session/i)
      return true
    end

    false
  rescue StandardError
    false
  end

  # Push a conversation reference to a remote instance
  def self.push_conversation_reference(instance_url:, for_pubkey:, conversation_id:, other_user:)
    instance_url = normalize_instance_url(instance_url)
    uri = URI.parse(instance_url)
    host_with_port = uri.host
    port = uri.port
    default_port = uri.scheme == "https" ? 443 : 80
    host_with_port += ":#{port}" if port && port != default_port

    protocol = Rails.env.development? ? "http" : "https"
    avatar_url = if other_user.avatar.attached?
      Rails.application.routes.url_helpers.rails_blob_url(
        other_user.avatar, host: Rails.application.config.x.instance_domain, protocol: protocol
      )
    end

    post_federation_json(
      host_with_port,
      "/federation/conversations/push_reference",
      body: {
        requesting_instance: Rails.application.config.x.instance_domain,
        for_pubkey: for_pubkey,
        conversation_id: conversation_id,
        instance_url: federation_instance_url,
        other_username: other_user.username,
        other_display_name: other_user.display_name,
        other_avatar_url: avatar_url,
        other_profile_color: other_user.profile_color
      }
    )
  end

  private

  def self.normalize_instance_url(url)
    url = url.to_s.strip
    url = "#{Rails.env.development? ? 'http' : 'https'}://#{url}" unless url.start_with?("http")
    url.chomp("/")
  end

  def self.federation_instance_url
    protocol = Rails.env.development? ? "http" : "https"
    "#{protocol}://#{Rails.application.config.x.instance_domain}"
  end

  def self.build_friend_request_event(user:, to_username:, to_discriminator:)
    protocol = Rails.env.development? ? "http" : "https"
    host = Rails.application.config.x.instance_domain

    avatar_url = if user.avatar.attached?
      Rails.application.routes.url_helpers.rails_blob_url(
        user.avatar, host: host, protocol: protocol
      )
    end

    content = {
      from_pubkey: user.nostr_public_key,
      from_username: user.username,
      from_display_name: user.display_name,
      from_discriminator: user.discriminator,
      from_avatar_url: avatar_url,
      from_profile_color: user.profile_color,
      to_username: to_username,
      to_discriminator: to_discriminator
    }.to_json

    tags = [
      ["d", "friend_request"],
      ["relay", "wss://#{host}"]
    ]

    created_at = Time.now.to_i

    serialized = [0, user.nostr_public_key, created_at, 30078, tags, content]
    id = Digest::SHA256.hexdigest(JSON.generate(serialized))

    message_bin = [id].pack("H*")
    private_key_bin = [user.nostr_private_key].pack("H*")
    signature = Schnorr.sign(message_bin, private_key_bin)
    sig_hex = signature.encode.unpack1("H*")

    {
      id: id,
      pubkey: user.nostr_public_key,
      created_at: created_at,
      kind: 30078,
      tags: tags,
      content: content,
      sig: sig_hex
    }
  end

  # Like post_federation_json but returns status code + parsed body
  def self.post_federation_json_raw(instance_url, path, body: {})
    url = "#{instance_url}#{path}"

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 10
    http.read_timeout = 15

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/json"
    request.body = body.to_json
    response = http.request(request)

    parsed = JSON.parse(response.body) rescue { "error" => response.body }
    { status: response.code.to_i, body: parsed }
  rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNREFUSED, SocketError => e
    raise FederationError, "Could not reach that instance: #{e.message}"
  end

  def self.fetch_federation_json(home_instance, path, token: nil)
    protocol = Rails.env.development? ? "http" : "https"
    requesting_instance = Rails.application.config.x.instance_domain
    url = "#{protocol}://#{home_instance}#{path}?requesting_instance=#{CGI.escape(requesting_instance)}"

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 10

    request = Net::HTTP::Get.new(uri.request_uri)
    request["X-Federation-Token"] = token if token.present?
    response = http.request(request)

    return nil unless response.code.to_i == 200

    JSON.parse(response.body)
  rescue StandardError => e
    Rails.logger.warn("Federation fetch failed for #{home_instance}#{path}: #{e.message}")
    nil
  end

  def self.post_federation_json(home_instance, path, token: nil, body: {})
    protocol = Rails.env.development? ? "http" : "https"
    requesting_instance = Rails.application.config.x.instance_domain
    url = "#{protocol}://#{home_instance}#{path}?requesting_instance=#{CGI.escape(requesting_instance)}"

    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 10

    request = Net::HTTP::Post.new(uri.request_uri)
    request["Content-Type"] = "application/json"
    request["X-Federation-Token"] = token if token.present?
    request.body = body.to_json
    response = http.request(request)

    return nil unless response.code.to_i == 200
    JSON.parse(response.body)
  rescue StandardError => e
    Rails.logger.warn("Federation post failed for #{home_instance}#{path}: #{e.message}")
    nil
  end

  def self.build_create_server_event(user:, instance_url:, name:, description:)
    content = { name: name, description: description, username: user.username }.to_json

    tags = [
      ["d", "create_server"],
      ["relay", "wss://#{Rails.application.config.x.instance_domain}"]
    ]

    created_at = Time.now.to_i

    # Build the event hash
    serialized = [0, user.nostr_public_key, created_at, 30078, tags, content]
    id = Digest::SHA256.hexdigest(JSON.generate(serialized))

    # Sign with Schnorr
    message_bin = [id].pack("H*")
    private_key_bin = [user.nostr_private_key].pack("H*")
    signature = Schnorr.sign(message_bin, private_key_bin)
    sig_hex = signature.encode.unpack1("H*")

    {
      id: id,
      pubkey: user.nostr_public_key,
      created_at: created_at,
      kind: 30078,
      tags: tags,
      content: content,
      sig: sig_hex
    }
  end
end
