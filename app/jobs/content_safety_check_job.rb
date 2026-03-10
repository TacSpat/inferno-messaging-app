class ContentSafetyCheckJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message
    return if message.hidden?

    ContentSafetyFilter.new(message).check!
  end
end
