class StoreImageHashesJob < ApplicationJob
  queue_as :default

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message&.files&.attached?

    ImageHasher.hash_message_attachments(message).each do |h|
      ContentHash.find_or_create_by!(
        hash_value: h[:hash_value],
        hash_type: h[:hash_type]
      ) do |ch|
        ch.media_type = h[:media_type]
        ch.original_filename = h[:original_filename]
        ch.message = message
      end
    end
  rescue => e
    Rails.logger.warn("[StoreImageHashesJob] Failed for message #{message_id}: #{e.message}")
  end
end
