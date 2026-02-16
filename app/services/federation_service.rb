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

  private

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
