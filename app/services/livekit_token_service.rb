class LivekitTokenService
  class TokenError < StandardError; end

  # Generate a LiveKit access token for a user joining a voice channel
  # Returns a JWT string
  def self.generate_token(user:, channel:, permissions: {})
    api_key = credentials[:api_key]
    api_secret = credentials[:api_secret]

    raise TokenError, "LiveKit credentials not configured" if api_key.blank? || api_secret.blank?

    token = LiveKit::AccessToken.new(api_key: api_key, api_secret: api_secret)
    token.identity = user.public_id
    token.name = user.display_name.presence || user.username

    can_publish = permissions[:speak] != false
    can_subscribe = true

    token.video_grant = LiveKit::VideoGrant.new(
      roomJoin: true,
      room: room_name(channel),
      canPublish: can_publish,
      canSubscribe: can_subscribe
    )

    token.to_jwt
  end

  # Verify an incoming webhook token
  def self.verify_token(token)
    api_key = credentials[:api_key]
    api_secret = credentials[:api_secret]

    verifier = LiveKit::TokenVerifier.new(api_key: api_key, api_secret: api_secret)
    verifier.verify(token)
  end

  # Consistent room naming: server_publicid_channel_publicid
  def self.room_name(channel)
    "#{channel.server.public_id}_#{channel.public_id}"
  end

  def self.livekit_url
    credentials[:url] || ENV["LIVEKIT_URL"] || "ws://localhost:7880"
  end

  def self.credentials
    creds = Rails.application.credentials.dig(:livekit) || {}
    {
      api_key: creds[:api_key] || ENV["LIVEKIT_API_KEY"],
      api_secret: creds[:api_secret] || ENV["LIVEKIT_API_SECRET"],
      url: creds[:url] || ENV["LIVEKIT_URL"]
    }
  end
  private_class_method :credentials
end
