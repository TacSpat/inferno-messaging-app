class NostrPublishJob < ApplicationJob
  queue_as :default

  # event_type: :profile, :contacts, or :relay_list
  def perform(user_id, event_type)
    user = User.find(user_id)
    return if user.nostr_public_key.blank?

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

    # Upload avatar/banner to Blossom and include URLs
    if user.avatar.attached?
      url = BlossomClientService.upload_attachment(user.avatar)
      profile_data[:picture] = url if url.present?
    end

    if user.banner.attached?
      url = BlossomClientService.upload_attachment(user.banner)
      profile_data[:banner] = url if url.present?
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
    tags = Contact.friends.map do |contact|
      relay_url = contact.relay_url.presence || LocalConfig.current.instance_relay_url.presence || ""
      [ "p", contact.pubkey, relay_url, contact.petname.presence || contact.effective_display_name ]
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
    instance_relay = LocalConfig.current.instance_relay_url
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
