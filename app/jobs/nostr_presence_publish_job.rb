class NostrPresencePublishJob < ApplicationJob
  queue_as :default

  # Publish NIP-38 Kind 30315 (user status) event to relays
  def perform(user_id, state)
    user = User.find_by(id: user_id)
    return unless user&.nostr_private_key.present?

    event = build_status_event(user, state)
    RelayService.publish_to_all(event)
  end

  private

  def build_status_event(user, state)
    content = state == "online" ? "" : state
    tags = [
      ["d", "general"],
      ["status", state]
    ]

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 30315,
      pubkey: user.nostr_public_key,
      content: content,
      tags: tags
    )
    signed = signer.sign(event)
    signed.to_json
  end
end
