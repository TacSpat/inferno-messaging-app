class NostrChannelReorderSyncJob < ApplicationJob
  queue_as :default

  # Publish channel reorder changes to remote instances via Nostr relay.
  # Remote instances receive these and update their local channel positions,
  # then broadcast to their ActionCable clients for instant UI updates.
  def perform(server_id, channels_data, categories_data, hierarchy_changed)
    owner = User.owner
    return unless owner&.nostr_private_key.present?

    server = Server.find_by(id: server_id)
    return unless server

    target_pubkeys = Set.new
    RelaySubscriptionManager.known_remote_owners(server.id).each do |pk|
      target_pubkeys.add(pk)
    end

    target_pubkeys.delete(owner.nostr_public_key)

    if target_pubkeys.empty?
      Rails.logger.info("[NostrChannelReorderSyncJob] No target pubkeys for server #{server_id} — skipping reorder sync")
      return
    end

    Rails.logger.info("[NostrChannelReorderSyncJob] Publishing reorder to #{target_pubkeys.size} target(s) for server #{server_id}")

    payload = {
      type: "channel_reorder_sync",
      server_nostr_group_id: server.nostr_group_id,
      channels: channels_data,
      categories: categories_data,
      hierarchy_changed: hierarchy_changed
    }.to_json

    target_pubkeys.each do |pubkey|
      publish_to(owner, pubkey, payload)
    end
  end

  private

  def publish_to(owner, target_pubkey, payload)
    conversation_key = Nip44Service.conversation_key(owner.nostr_private_key, target_pubkey)
    encrypted = Nip44Service.encrypt(payload, conversation_key)

    signer = Nostr::Signer.new(private_key: owner.nostr_private_key)
    event = Nostr::Event.new(
      kind: 14,
      pubkey: owner.nostr_public_key,
      content: encrypted,
      tags: [ [ "p", target_pubkey ] ]
    )
    signed = signer.sign(event)
    RelayService.publish_to_all(signed.to_json)
  rescue => e
    Rails.logger.warn("[NostrChannelReorderSyncJob] Failed to publish to #{target_pubkey[0..15]}: #{e.message}")
  end
end
