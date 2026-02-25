class NostrVoiceStateSyncJob < ApplicationJob
  queue_as :default

  # Publish voice state changes (join/leave) to remote instances via Nostr relay.
  # Remote instances receive these and broadcast to their local ActionCable clients.
  def perform(action, server_id, channel_public_id, user_public_id, username, avatar_url, profile_color)
    owner = User.owner
    return unless owner&.nostr_private_key.present?

    server = Server.find_by(id: server_id)
    return unless server

    # Collect target pubkeys: remote voice provider pubkeys + cached remote instance owners
    target_pubkeys = Set.new
    server.server_voice_providers.where.not(provider_pubkey: nil).pluck(:provider_pubkey).each do |pk|
      target_pubkeys.add(pk)
    end
    RelaySubscriptionManager.known_remote_owners(server.id).each do |pk|
      target_pubkeys.add(pk)
    end

    # Don't send to ourselves
    target_pubkeys.delete(owner.nostr_public_key)

    if target_pubkeys.empty?
      Rails.logger.info("[NostrVoiceStateSyncJob] No target pubkeys for server #{server_id} — skipping #{action} sync")
      return
    end

    Rails.logger.info("[NostrVoiceStateSyncJob] Publishing #{action} to #{target_pubkeys.size} target(s) for #{user_public_id}")

    payload = {
      type: "voice_state_sync",
      action: action,
      server_nostr_group_id: server.nostr_group_id,
      channel_id: channel_public_id,
      user_id: user_public_id,
      username: username,
      avatar_url: avatar_url,
      profile_color: profile_color
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
      tags: [["p", target_pubkey]]
    )
    signed = signer.sign(event)
    RelayService.publish_to_all(signed.to_json)
  rescue => e
    Rails.logger.warn("[NostrVoiceStateSyncJob] Failed to publish to #{target_pubkey[0..15]}: #{e.message}")
  end
end
