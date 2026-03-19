namespace :nostr do
  desc "Generate Nostr keypairs for existing users that don't have one"
  task backfill_keys: :environment do
    users = User.where(nostr_public_key: nil)
    total = users.count
    puts "Generating keypairs for #{total} users..."

    users.find_each.with_index do |user, i|
      user.generate_nostr_keypair
      print "\r  #{i + 1}/#{total}"
    end

    puts "\nDone."
  end

  desc "Refresh remote user profiles from relays"
  task refresh_profiles: :environment do
    stale = RemoteUser.where("updated_at < ?", 1.hour.ago)
    total = stale.count
    puts "Refreshing #{total} stale remote profiles..."

    stale.find_each.with_index do |remote_user, i|
      NostrProfileFetchJob.perform_later(remote_user.nostr_public_key)
      print "\r  Queued #{i + 1}/#{total}"
    end

    puts "\nDone. Jobs queued for processing."
  end

  desc "Poll shared channels for new inbound NIP-29 group messages"
  task poll_shared_channels: :environment do
    shared_count = Channel.shared_channels.count
    if shared_count > 0
      puts "Polling #{shared_count} shared channels..."
      NostrGroupSubscriptionJob.perform_now
      puts "Done."
    else
      puts "No shared channels configured."
    end
  end

  desc "Publish all local user profiles to relays"
  task publish_all_profiles: :environment do
    users = User.local.where.not(nostr_public_key: nil)
    total = users.count
    puts "Publishing #{total} profiles to relays..."

    users.find_each.with_index do |user, i|
      NostrPublishJob.perform_later(user.id, :profile)
      NostrPublishJob.perform_later(user.id, :relay_list)
      print "\r  Queued #{i + 1}/#{total}"
    end

    puts "\nDone. Jobs queued for processing."
  end

  desc "Generate a Nostr keypair for the instance (paste output into .env)"
  task generate_instance_keypair: :environment do
    private_key = Nostr::Key.generate_private_key
    public_key = Nostr::Key.get_public_key(private_key)

    puts ""
    puts "Add these to your .env file:"
    puts ""
    puts "NOSTR_INSTANCE_PRIVATE_KEY=#{private_key}"
    puts "NOSTR_INSTANCE_PUBLIC_KEY=#{public_key}"
    puts ""
    puts "Public key (npub): #{Nostr::Bech32.encode_npub(public_key)}"
    puts ""
  end

  desc "Sync allowed pubkeys to strfry relay config file"
  task sync_strfry_pubkeys: :environment do
    output_path = ENV.fetch("STRFRY_PUBKEYS_FILE", "/etc/strfry/allowed_pubkeys.txt")

    pubkeys = []

    # Local users
    User.local.where.not(nostr_public_key: nil).find_each do |user|
      pubkeys << user.nostr_public_key
    end

    # Authorized remote users
    RemoteUser.find_each do |remote_user|
      pubkeys << remote_user.nostr_public_key
    end

    # Instance pubkey
    instance_pubkey = Rails.application.config.nostr[:instance_public_key]
    pubkeys << instance_pubkey if instance_pubkey.present?

    pubkeys.uniq!

    File.write(output_path, pubkeys.join("\n") + "\n")
    puts "Wrote #{pubkeys.size} pubkeys to #{output_path}"
  end

  desc "Re-publish all channel messages to relays with current tags (spoiler, sticker, etc.)"
  task republish_messages: :environment do
    messages = Message.joins(channel: :server)
                      .where.not(channels: { nostr_group_id: nil })
                      .where.not(system_message: true)
                      .includes(:user, channel: :server)

    total = messages.count
    puts "Re-publishing #{total} messages to relays..."

    published = 0
    skipped = 0
    errors = 0

    messages.find_each.with_index do |message, i|
      user = message.user
      channel = message.channel

      # Skip messages without a local user (remote messages)
      unless user&.nostr_private_key.present?
        skipped += 1
        next
      end

      # Build content — resolve Active Storage URLs to Blossom URLs
      event_content = message.content || ""
      event_content = event_content.gsub(%r{/rails/active_storage/blobs/(?:redirect/)?([^/\s]+)/[^\s]+}) do |match|
        signed_id = $1
        blob = ActiveStorage::Blob.find_signed(signed_id) rescue nil
        next match unless blob
        cached = blob.metadata&.dig("blossom_url")
        next cached if cached.present?
        match
      end

      # Build tags with all current attributes
      tags = [["h", channel.nostr_group_id]]
      tags << ["sticker"] if message.is_sticker?
      tags << ["spoiler"] if message.spoiler?

      if channel.encrypted? && channel.channel_public_key.present?
        conversation_key = Nip44Service.conversation_key(user.nostr_private_key, channel.channel_public_key)
        event_content = Nip44Service.encrypt(event_content, conversation_key)
        tags << ["encrypted", "nip44"]
        tags << ["channel_pubkey", channel.channel_public_key]
      end

      # Sign and publish
      signer = Nostr::Signer.new(private_key: user.nostr_private_key)
      event = Nostr::Event.new(
        kind: 9,
        pubkey: user.nostr_public_key,
        content: event_content,
        tags: tags
      )
      signed = signer.sign(event)
      signed_hash = signed.to_json

      message.update_columns(nostr_event_id: signed.id)

      NostrEventLog.create!(
        event_id: signed.id,
        kind: 9,
        pubkey: user.nostr_public_key,
        message: message,
        channel: channel,
        direction: "outbound",
        event_created_at: message.created_at
      )

      RelayService.publish_to_all(signed_hash)
      published += 1
      print "\r  #{i + 1}/#{total} (#{published} published, #{skipped} skipped)"
    rescue => e
      errors += 1
      puts "\n  Error on message #{message.id}: #{e.message}"
    end

    puts "\nDone. Published: #{published}, Skipped: #{skipped}, Errors: #{errors}"
  end
end
