class NostrGroupPublishJob < ApplicationJob
  queue_as :default

  NIP29_GROUP_CHAT_MESSAGE = 9

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return unless message
    return unless message.channel&.shared?
    return if message.user&.remote?
    return if message.user&.nostr_public_key.blank?

    channel = message.channel
    user = message.user

    # Build NIP-29 Kind 9 event
    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: NIP29_GROUP_CHAT_MESSAGE,
      pubkey: user.nostr_public_key,
      content: message.content || "",
      tags: [
        [ "h", channel.nostr_group_id ]
      ]
    )
    signed = signer.sign(event)
    signed_event = signed.to_json

    # Publish to the channel's specific relay
    relay = RelayConnection.find_by(url: channel.nostr_relay_url) ||
            RelayConnection.new(url: channel.nostr_relay_url, status: "active")

    result = RelayService.publish_to_relay(relay, signed_event)

    # Log the outbound event
    NostrEventLog.create!(
      event_id: signed_event[:id],
      kind: NIP29_GROUP_CHAT_MESSAGE,
      pubkey: user.nostr_public_key,
      message: message,
      channel: channel,
      direction: "outbound",
      event_created_at: Time.at(signed_event[:created_at])
    )

    if result[:success]
      Rails.logger.info("Published message #{message.id} to NIP-29 group #{channel.nostr_group_id}")
    else
      Rails.logger.warn("Failed to publish message #{message.id} to relay: #{result[:message]}")
    end
  end
end
