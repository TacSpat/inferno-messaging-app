class NostrGroupPublishJob < ApplicationJob
  queue_as :default

  NIP29_GROUP_CHAT_MESSAGE = 9

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message&.channel
    return if message.user&.nostr_public_key.blank?
    return if message.nostr_event_id.present? # Already published

    channel = message.channel
    user = message.user

    # Build NIP-29 Kind 9 event
    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: NIP29_GROUP_CHAT_MESSAGE,
      pubkey: user.nostr_public_key,
      content: message.content || "",
      tags: [
        ["h", channel.nostr_group_id]
      ]
    )
    signed = signer.sign(event)
    signed_json = signed.to_json

    # Store the signed event on the message
    message.update_columns(
      nostr_event_id: signed[:id] || signed["id"],
      nostr_event_json: signed_json
    )

    # Publish to all relay URLs for this channel
    relay_urls = channel.effective_relay_urls
    relay_urls.each do |url|
      relay = RelayConnection.find_or_create_for_relay(url) ||
              RelayConnection.new(url: url, status: "active")
      result = RelayService.publish_to_relay(relay, signed_json)

      if result[:success]
        Rails.logger.info("Published message #{message.id} to #{url}")
      else
        Rails.logger.warn("Failed to publish message #{message.id} to #{url}: #{result[:message]}")
      end
    end

    # Log the outbound event
    NostrEventLog.create!(
      event_id: signed[:id] || signed["id"],
      kind: NIP29_GROUP_CHAT_MESSAGE,
      pubkey: user.nostr_public_key,
      message: message,
      channel: channel,
      direction: "outbound",
      event_created_at: Time.at(signed[:created_at] || signed["created_at"] || Time.current.to_i)
    )
  rescue ActiveRecord::RecordNotUnique
    # Event already logged
  end
end
