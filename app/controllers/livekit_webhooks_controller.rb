class LivekitWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    body = request.body.read
    auth_header = request.headers["Authorization"]

    # Verify the webhook token
    if auth_header.present?
      token = auth_header.sub("Bearer ", "")
      begin
        LivekitTokenService.verify_token(token)
      rescue => e
        Rails.logger.warn("LiveKit webhook verification failed: #{e.message}")
        return head :unauthorized
      end
    end

    event = JSON.parse(body)
    event_type = event["event"]

    case event_type
    when "participant_left"
      handle_participant_left(event)
    end

    head :ok
  rescue JSON::ParserError
    head :bad_request
  end

  private

  def handle_participant_left(event)
    participant = event.dig("participant")
    return unless participant

    identity = participant["identity"]
    room_name = event.dig("room", "name")
    return unless identity && room_name

    # Room name format: server_public_id_channel_public_id
    voice_state = VoiceState.joins(:user).find_by(users: { public_id: identity })
    return unless voice_state

    server = voice_state.server
    ServerChannel.broadcast_to(server, {
      type: "voice_state_leave",
      channel_id: voice_state.channel.public_id,
      user_id: voice_state.user.public_id
    })

    voice_state.destroy!
  end
end
