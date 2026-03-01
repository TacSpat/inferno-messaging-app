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
    tags = [ [ "h", channel.nostr_group_id ] ]

    # NIP-30: Include custom emoji tags so other clients can render them
    if message.content.present? && channel.server
      emoji_names = message.content.scan(/:([a-z0-9_]+):/).flatten.uniq
      if emoji_names.any?
        server_emojis = channel.server.server_emojis
                          .where(name: emoji_names)
                          .includes(image_attachment: :blob)
        server_emojis.each do |emoji|
          next unless emoji.image.attached?
          url = Rails.application.routes.url_helpers.rails_blob_path(emoji.image, only_path: true)
          tags << [ "emoji", emoji.name, url ]
        end
      end
    end

    event_content = message.content || ""

    # NIP-44 encrypt content for encrypted channels
    if channel.encrypted? && channel.channel_public_key.present?
      conversation_key = Nip44Service.conversation_key(user.nostr_private_key, channel.channel_public_key)
      event_content = Nip44Service.encrypt(event_content, conversation_key)
      tags << [ "encrypted", "nip44" ]
      tags << [ "channel_pubkey", channel.channel_public_key ]
    end

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: NIP29_GROUP_CHAT_MESSAGE,
      pubkey: user.nostr_public_key,
      content: event_content,
      tags: tags
    )
    signed = signer.sign(event)
    signed_hash = signed.to_json  # Returns a Hash (gem override)

    # Store the signed event on the message
    message.update_columns(
      nostr_event_id: signed.id,
      nostr_event_json: JSON.generate(signed_hash)
    )

    # Publish to all active relays
    RelayService.publish_to_all(signed_hash)

    # Log the outbound event
    NostrEventLog.create!(
      event_id: signed.id,
      kind: NIP29_GROUP_CHAT_MESSAGE,
      pubkey: user.nostr_public_key,
      message: message,
      channel: channel,
      direction: "outbound",
      event_created_at: Time.at(signed.created_at || Time.current.to_i)
    )
  rescue ActiveRecord::RecordNotUnique
    # Event already logged
  end
end
