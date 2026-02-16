class LivekitRoomService
  class RoomError < StandardError; end

  def self.mute_participant(channel:, identity:, track_sid:, muted: true)
    client.mute_published_track(
      room: LivekitTokenService.room_name(channel),
      identity: identity,
      track_sid: track_sid,
      muted: muted
    )
  rescue => e
    raise RoomError, "Failed to mute participant: #{e.message}"
  end

  def self.remove_participant(channel:, identity:)
    client.remove_participant(
      room: LivekitTokenService.room_name(channel),
      identity: identity
    )
  rescue => e
    raise RoomError, "Failed to remove participant: #{e.message}"
  end

  def self.list_participants(channel:)
    client.list_participants(
      room: LivekitTokenService.room_name(channel)
    )
  rescue => e
    raise RoomError, "Failed to list participants: #{e.message}"
  end

  def self.client
    credentials = Rails.application.credentials.dig(:livekit) || {}
    url = credentials[:url] || ENV["LIVEKIT_URL"] || "http://localhost:7880"
    api_key = credentials[:api_key] || ENV["LIVEKIT_API_KEY"]
    api_secret = credentials[:api_secret] || ENV["LIVEKIT_API_SECRET"]

    LiveKit::RoomServiceClient.new(url, api_key: api_key, api_secret: api_secret)
  end
  private_class_method :client
end
