require "net/http"
require "json"

class LivekitRoomService
  class Error < StandardError; end

  # Initialize with a provider User whose LiveKit credentials to use.
  def initialize(provider)
    @provider = provider
  end

  # Health check — hit the LiveKit server's health endpoint.
  # Returns true if the server responds with 200.
  def health_check
    return false unless @provider.livekit_url.present?

    uri = health_uri
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 5
    http.read_timeout = 5
    http.verify_mode = OpenSSL::SSL::VERIFY_PEER

    response = http.request(Net::HTTP::Get.new(uri.path))
    response.is_a?(Net::HTTPSuccess)
  rescue => e
    Rails.logger.warn("[LivekitRoomService] Health check failed: #{e.message}")
    false
  end

  # List participants in a room via LiveKit's Twirp API.
  def list_participants(room_name)
    twirp_request("ListParticipants", { room: room_name })
  end

  # Remove a participant from a room (kick).
  def remove_participant(room_name, identity)
    twirp_request("RemoveParticipant", { room: room_name, identity: identity })
  end

  # Mute a participant's published track.
  def mute_participant(room_name, identity, track_sid, muted: true)
    twirp_request("MutePublishedTrack", {
      room: room_name,
      identity: identity,
      track_sid: track_sid,
      muted: muted
    })
  end

  private

  def health_uri
    url = @provider.livekit_url.sub(%r{^wss://}, "https://").sub(%r{^ws://}, "http://")
    URI("#{url.chomp('/')}/")
  end

  def twirp_uri(method)
    url = @provider.livekit_url.sub(%r{^wss://}, "https://").sub(%r{^ws://}, "http://")
    URI("#{url.chomp('/')}/twirp/livekit.RoomService/#{method}")
  end

  def twirp_request(method, body)
    uri = twirp_uri(method)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 10
    http.read_timeout = 10

    request = Net::HTTP::Post.new(uri.path)
    request["Content-Type"] = "application/json"
    request["Authorization"] = "Bearer #{generate_api_token}"
    request.body = JSON.generate(body)

    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      raise Error, "LiveKit API error: HTTP #{response.code} - #{response.body}"
    end

    JSON.parse(response.body)
  end

  def generate_api_token
    now = Time.now.to_i
    payload = {
      iss: @provider.livekit_api_key,
      exp: now + 60,
      nbf: now - 5,
      iat: now,
      video: { roomAdmin: true, roomList: true }
    }
    JWT.encode(payload, @provider.livekit_api_secret, "HS256")
  end
end
