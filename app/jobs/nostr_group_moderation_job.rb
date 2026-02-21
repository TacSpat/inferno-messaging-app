class NostrGroupModerationJob < ApplicationJob
  queue_as :default

  NIP29_DELETE_EVENT = 9005
  NIP29_REMOVE_USER = 9001

  # Publish a NIP-29 moderation event to the group relay
  # action: :delete_event or :remove_user
  def perform(action, channel_id:, moderator_id:, target_event_id: nil, target_pubkey: nil, reason: nil)
    channel = Channel.find_by(id: channel_id)
    return unless channel

    moderator = User.find_by(id: moderator_id)
    return if moderator.nil? || moderator.nostr_public_key.blank?

    case action.to_sym
    when :delete_event
      publish_delete_event(channel, moderator, target_event_id, reason)
    when :remove_user
      publish_remove_user(channel, moderator, target_pubkey, reason)
    end
  end

  private

  # Kind 9005: Delete an event from the group
  def publish_delete_event(channel, moderator, target_event_id, reason)
    return if target_event_id.blank?

    signer = Nostr::Signer.new(private_key: moderator.nostr_private_key)
    event = Nostr::Event.new(
      kind: NIP29_DELETE_EVENT,
      pubkey: moderator.nostr_public_key,
      content: reason || "",
      tags: [
        [ "h", channel.nostr_group_id ],
        [ "e", target_event_id ]
      ]
    )
    signed = signer.sign(event)

    RelayService.publish_to_all(signed.to_json)
    Rails.logger.info("Published delete event for #{target_event_id} in group #{channel.nostr_group_id}")
  end

  # Kind 9001: Remove a user from the group
  def publish_remove_user(channel, moderator, target_pubkey, reason)
    return if target_pubkey.blank?

    signer = Nostr::Signer.new(private_key: moderator.nostr_private_key)
    event = Nostr::Event.new(
      kind: NIP29_REMOVE_USER,
      pubkey: moderator.nostr_public_key,
      content: reason || "",
      tags: [
        [ "h", channel.nostr_group_id ],
        [ "p", target_pubkey ]
      ]
    )
    signed = signer.sign(event)

    RelayService.publish_to_all(signed.to_json)
    Rails.logger.info("Published remove-user for #{target_pubkey[0..15]}... from group #{channel.nostr_group_id}")
  end
end
