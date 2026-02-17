class NostrProfileFetchJob < ApplicationJob
  queue_as :default

  def perform(nostr_public_key)
    remote_user = RemoteUser.find_by(nostr_public_key: nostr_public_key)
    return unless remote_user

    # Fetch Kind 0 (profile) events for this pubkey from all active relays
    filter = {
      kinds: [ 0 ],
      authors: [ nostr_public_key ],
      limit: 1
    }

    events = RelayService.fetch_from_all(filter)
    return if events.empty?

    # Use the most recent event
    latest = events.max_by { |e| e["created_at"] || 0 }
    update_remote_profile(remote_user, latest)
  end

  private

  def update_remote_profile(remote_user, event)
    content = JSON.parse(event["content"]) rescue {}
    return if content.empty?

    attrs = {}
    attrs[:display_name] = content["display_name"].presence || content["name"] if content["display_name"].present? || content["name"].present?
    attrs[:username] = content["name"] if content["name"].present?
    attrs[:bio] = content["about"] if content["about"].present?
    attrs[:avatar_url] = content["picture"] if content["picture"].present?

    remote_user.update!(attrs) if attrs.any?

    # Also update the shadow user if it exists
    if remote_user.shadow_user
      shadow_attrs = {}
      shadow_attrs[:display_name] = attrs[:display_name] if attrs[:display_name]
      remote_user.shadow_user.update!(shadow_attrs) if shadow_attrs.any?
    end

    Rails.logger.info("Updated remote profile for #{remote_user.nostr_public_key[0..15]}... from relay")
  end
end
