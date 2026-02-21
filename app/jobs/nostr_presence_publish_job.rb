class NostrPresencePublishJob < ApplicationJob
  queue_as :default

  # Publish NIP-38 Kind 30315 (user status) event to relays
  def perform(user_id, state)
    user = User.find_by(id: user_id)
    return unless user&.nostr_private_key.present?

    event = build_status_event(user, state)
    relay_urls = RelayConnection.active.pluck(:url)

    relay_urls.each do |url|
      RelayService.publish_to_relay(url, event)
    rescue => e
      Rails.logger.warn("Failed to publish presence to #{url}: #{e.message}")
    end
  end

  private

  def build_status_event(user, state)
    content = state == "online" ? "" : state
    tags = [
      ["d", "general"],
      ["status", state]
    ]

    event_data = {
      pubkey: user.nostr_public_key,
      created_at: Time.now.to_i,
      kind: 30315,
      tags: tags,
      content: content
    }

    serialized = [0, event_data[:pubkey], event_data[:created_at], event_data[:kind], event_data[:tags], event_data[:content]]
    event_data[:id] = Digest::SHA256.hexdigest(JSON.generate(serialized))

    schnorr_key = Nostr::Key.new(user.nostr_private_key)
    event_data[:sig] = schnorr_key.sign(event_data[:id])

    event_data
  end
end
