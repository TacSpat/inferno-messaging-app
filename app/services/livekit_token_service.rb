require "jwt"

class LivekitTokenService
  class ConfigurationError < StandardError; end

  # Generate a LiveKit access token for a user joining a voice channel.
  # provider: the User whose LiveKit credentials power this session.
  # Returns a JWT string that the client uses with livekit-client.
  def self.generate_token(user:, channel:, server:, provider:, ttl: 6.hours)
    raise ConfigurationError, "Voice provider has no LiveKit credentials" unless provider.livekit_configured?

    api_key = provider.livekit_api_key
    api_secret = provider.livekit_api_secret

    room_name = room_name_for(server, channel)
    identity = user.public_id
    name = user.display_name.presence || user.username

    # Determine permissions from user's role
    membership = user.server_memberships.find_by(server: server)
    can_publish = membership&.has_permission?("speak") != false
    can_subscribe = membership&.has_permission?("connect_voice") != false

    now = Time.now.to_i
    payload = {
      iss: api_key,
      sub: identity,
      name: name,
      exp: now + ttl.to_i,
      nbf: now - 5,
      iat: now,
      jti: SecureRandom.uuid,
      video: {
        roomJoin: true,
        room: room_name,
        canPublish: can_publish,
        canSubscribe: can_subscribe,
        canPublishData: true
      },
      metadata: {
        user_id: user.public_id,
        avatar_url: user.effective_avatar_url,
        profile_color: user.profile_color
      }.to_json
    }

    JWT.encode(payload, api_secret, "HS256")
  end

  def self.room_name_for(server, channel)
    "srv-#{server.public_id}-#{channel.public_id}"
  end
end
