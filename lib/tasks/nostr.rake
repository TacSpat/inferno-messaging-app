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
end
