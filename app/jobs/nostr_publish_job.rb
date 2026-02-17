class NostrPublishJob < ApplicationJob
  queue_as :default

  # event_type: :profile, :contacts, or :relay_list
  def perform(user_id, event_type)
    user = User.find(user_id)
    return if user.remote? || user.nostr_public_key.blank?

    signed_event = case event_type.to_sym
    when :profile
      build_profile_event(user)
    when :contacts
      build_contacts_event(user)
    when :relay_list
      build_relay_list_event(user)
    else
      Rails.logger.warn("NostrPublishJob: Unknown event type '#{event_type}'")
      return
    end

    results = RelayService.publish_to_all(signed_event)

    results.each do |relay_url, result|
      if result[:success]
        Rails.logger.info("Published #{event_type} event to #{relay_url}")
      else
        Rails.logger.warn("Failed to publish #{event_type} to #{relay_url}: #{result[:message]}")
      end
    end

    # Update tracking timestamps
    case event_type.to_sym
    when :profile
      user.update_column(:nostr_profile_published_at, Time.current)
    when :contacts
      user.update_column(:nostr_contacts_published_at, Time.current)
    end
  end

  private

  # Kind 0: Profile metadata
  def build_profile_event(user)
    profile_data = {
      name: user.username,
      display_name: user.display_name.presence || user.username,
      about: user.bio.presence || "",
      nip05: user.nip05_identifier
    }

    # Include avatar URL if attached
    if user.avatar.attached?
      profile_data[:picture] = Rails.application.routes.url_helpers.rails_blob_url(
        user.avatar,
        host: Rails.application.config.x.instance_domain
      )
    end

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 0, # METADATA
      pubkey: user.nostr_public_key,
      content: JSON.generate(profile_data),
      tags: []
    )
    signer.sign(event)
    event.to_json
  end

  # Kind 3: Contacts list
  def build_contacts_event(user)
    tags = user.friends.where.not(nostr_public_key: nil).map do |friend|
      relay_url = InstanceConfig.current.instance_relay_url.presence || ""
      [ "p", friend.nostr_public_key, relay_url, friend.display_name.presence || friend.username ]
    end

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 3, # CONTACT_LIST
      pubkey: user.nostr_public_key,
      content: "",
      tags: tags
    )
    signer.sign(event)
    event.to_json
  end

  # Kind 10002: Relay list metadata
  def build_relay_list_event(user)
    tags = RelayConnection.active.pluck(:url).flat_map do |url|
      [ [ "r", url, "read" ], [ "r", url, "write" ] ]
    end

    # Also include the instance relay if configured
    instance_relay = InstanceConfig.current.instance_relay_url
    if instance_relay.present? && tags.none? { |t| t[1] == instance_relay }
      tags << [ "r", instance_relay, "read" ]
      tags << [ "r", instance_relay, "write" ]
    end

    signer = Nostr::Signer.new(private_key: user.nostr_private_key)
    event = Nostr::Event.new(
      kind: 10002, # RELAY_LIST_METADATA
      pubkey: user.nostr_public_key,
      content: "",
      tags: tags
    )
    signer.sign(event)
    event.to_json
  end
end
