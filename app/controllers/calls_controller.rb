require "jwt"

class CallsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_conversation
  before_action :set_call, only: %i[accept decline join hangup]

  # POST /conversations/:conversation_id/calls
  def create
    # End any existing active calls for this conversation
    @conversation.calls.active.update_all(status: "ended", ended_at: Time.current)

    provider = find_livekit_provider
    unless provider
      render json: { error: "Voice calling requires LiveKit configuration" }, status: :unprocessable_entity
      return
    end

    @call = @conversation.calls.create!(
      initiated_by: current_user,
      status: "ringing"
    )
    @call.update!(livekit_room_name: @call.room_name)
    @call.call_participants.create!(user: current_user, joined_at: Time.current)

    token = generate_call_token(provider, @call, current_user)

    # Broadcast incoming call to other participants
    ConversationChannel.broadcast_to(@conversation, {
      type: "incoming_call",
      call_id: @call.public_id,
      caller_id: current_user.public_id,
      caller_name: current_user.display_name.presence || current_user.username,
      caller_avatar: current_user.effective_avatar_url
    })

    # Also notify via user_notifications so users see it outside the conversation
    @conversation.participants.where.not(id: current_user.id).find_each do |user|
      ActionCable.server.broadcast("user_notifications_#{user.id}", {
        type: "incoming_call",
        conversation_id: @conversation.public_id,
        call_id: @call.public_id,
        caller_name: current_user.display_name.presence || current_user.username,
        caller_avatar: current_user.effective_avatar_url
      })
    end

    # Auto-end the call after 30 seconds if not answered
    CallRingTimeoutJob.set(wait: 30.seconds).perform_later(@call.id)

    callee_name = @conversation.display_name(current_user)

    render json: {
      call_id: @call.public_id,
      token: token,
      livekit_url: provider.livekit_url,
      room_name: @call.livekit_room_name,
      callee_name: callee_name
    }
  end

  # POST /conversations/:conversation_id/calls/:id/accept
  def accept
    unless @call.joinable?
      render json: { error: "Call is no longer available" }, status: :unprocessable_entity
      return
    end

    provider = find_livekit_provider
    unless provider
      render json: { error: "Voice calling requires LiveKit configuration" }, status: :unprocessable_entity
      return
    end

    @call.update!(status: "active", started_at: Time.current) if @call.status == "ringing"
    @call.call_participants.find_or_create_by!(user: current_user) do |cp|
      cp.joined_at = Time.current
    end

    token = generate_call_token(provider, @call, current_user)

    ConversationChannel.broadcast_to(@conversation, {
      type: "call_accepted",
      call_id: @call.public_id,
      user_id: current_user.public_id,
      user_name: current_user.display_name.presence || current_user.username
    })

    render json: {
      call_id: @call.public_id,
      token: token,
      livekit_url: provider.livekit_url,
      room_name: @call.livekit_room_name
    }
  end

  # POST /conversations/:conversation_id/calls/:id/decline
  def decline
    return head :ok unless @call.joinable?

    @call.update!(status: "declined", ended_at: Time.current)

    ConversationChannel.broadcast_to(@conversation, {
      type: "call_declined",
      call_id: @call.public_id,
      user_id: current_user.public_id
    })

    create_call_system_message

    head :ok
  end

  # POST /conversations/:conversation_id/calls/:id/join
  def join
    unless @call.joinable?
      render json: { error: "Call is no longer available" }, status: :unprocessable_entity
      return
    end

    provider = find_livekit_provider
    unless provider
      render json: { error: "Voice calling requires LiveKit configuration" }, status: :unprocessable_entity
      return
    end

    @call.update!(status: "active", started_at: Time.current) if @call.status == "ringing"
    @call.call_participants.find_or_create_by!(user: current_user) do |cp|
      cp.joined_at = Time.current
    end

    token = generate_call_token(provider, @call, current_user)

    ConversationChannel.broadcast_to(@conversation, {
      type: "participant_joined",
      call_id: @call.public_id,
      user_id: current_user.public_id,
      user_name: current_user.display_name.presence || current_user.username
    })

    render json: {
      call_id: @call.public_id,
      token: token,
      livekit_url: provider.livekit_url,
      room_name: @call.livekit_room_name
    }
  end

  # POST /conversations/:conversation_id/calls/:id/hangup
  def hangup
    participant = @call.call_participants.find_by(user: current_user)
    if participant && participant.left_at.nil?
      now = Time.current
      dur = participant.joined_at ? (now - participant.joined_at).to_i : 0
      participant.update!(left_at: now, duration_seconds: dur)
    end

    # If all participants have left, end the call
    active_count = @call.call_participants.where(left_at: nil).count
    if active_count == 0
      @call.update!(status: "ended", ended_at: Time.current)
      create_call_system_message
    end

    ConversationChannel.broadcast_to(@conversation, {
      type: "call_ended",
      call_id: @call.public_id,
      user_id: current_user.public_id,
      active_count: active_count
    })

    head :ok
  end

  private

  def set_conversation
    @conversation = Conversation.find_by!(public_id: params[:conversation_id])
    unless @conversation.participants.include?(current_user)
      head :forbidden
    end
  end

  def set_call
    @call = @conversation.calls.find_by!(public_id: params[:id])
  end

  def find_livekit_provider
    # Check if any participant of the conversation has LiveKit configured
    @conversation.participants.find(&:livekit_configured?) || current_user.tap { |u| return nil unless u.livekit_configured? }
  end

  def generate_call_token(provider, call, user)
    api_key = provider.livekit_api_key
    api_secret = provider.livekit_api_secret
    now = Time.now.to_i

    payload = {
      iss: api_key,
      sub: user.public_id,
      name: user.display_name.presence || user.username,
      exp: now + 6.hours.to_i,
      nbf: now - 5,
      iat: now,
      jti: SecureRandom.uuid,
      video: {
        roomJoin: true,
        room: call.livekit_room_name,
        canPublish: true,
        canSubscribe: true,
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

  def create_call_system_message
    duration = @call.duration
    Message.create!(
      conversation: @conversation,
      user: @call.initiated_by,
      system_message: true,
      content: "call:#{@call.public_id}:#{@call.status}:#{duration || 0}"
    )
  end
end
