class CallRingTimeoutJob < ApplicationJob
  queue_as :default

  def perform(call_id)
    call = Call.find_by(id: call_id)
    return unless call&.status == "ringing"

    call.update!(status: "ended", ended_at: Time.current)

    # Create missed call system message
    Message.create!(
      conversation: call.conversation,
      user: call.initiated_by,
      system_message: true,
      content: "call:#{call.public_id}:missed:0"
    )

    ConversationChannel.broadcast_to(call.conversation, {
      type: "call_ended",
      call_id: call.public_id,
      active_count: 0
    })
  end
end
