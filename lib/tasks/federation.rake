namespace :federation do
  desc "Rewrite stored federation URLs when INSTANCE_DOMAIN changes. Usage: rails federation:rewrite_domain OLD=http://localhost:3005 NEW=https://beast-mint.tail84ddc9.ts.net"
  task rewrite_domain: :environment do
    old_raw = ENV["OLD"]
    new_raw = ENV["NEW"]

    abort "Usage: rails federation:rewrite_domain OLD=<old_url_or_domain> NEW=<new_url_or_domain>" if old_raw.blank? || new_raw.blank?

    old_url = FederationService.normalize_instance_url_for_storage(old_raw)
    new_url = FederationService.normalize_instance_url_for_storage(new_raw)

    old_domain = URI.parse(old_url).host rescue old_raw
    new_domain = extract_bare_domain(new_url)

    puts "Rewriting federation URLs:"
    puts "  OLD: #{old_url} (domain: #{old_domain})"
    puts "  NEW: #{new_url} (domain: #{new_domain})"
    puts

    counts = { servers: 0, conversations: 0, friends: 0, remote_users: 0 }

    # Rewrite RemoteServerReference
    RemoteServerReference.where("remote_instance_url LIKE ?", "%#{old_domain}%").find_each do |ref|
      ref.update_columns(remote_instance_url: new_url)
      counts[:servers] += 1
    end

    # Rewrite RemoteConversationReference
    RemoteConversationReference.where("remote_instance_url LIKE ?", "%#{old_domain}%").find_each do |ref|
      ref.update_columns(remote_instance_url: new_url)
      counts[:conversations] += 1
    end

    # Rewrite RemoteFriendReference
    RemoteFriendReference.where("remote_instance_url LIKE ?", "%#{old_domain}%").find_each do |ref|
      ref.update_columns(remote_instance_url: new_url)
      counts[:friends] += 1
    end

    # Rewrite RemoteUser home_instance (bare domain, no protocol)
    RemoteUser.where("home_instance LIKE ?", "%#{old_domain}%").find_each do |ru|
      ru.update_columns(home_instance: new_domain)
      counts[:remote_users] += 1
    end

    puts "Updated #{counts[:servers]} server refs, #{counts[:conversations]} conversation refs, #{counts[:friends]} friend refs, #{counts[:remote_users]} remote users"

    # Deduplicate after rewrite
    puts
    puts "Running deduplication..."
    Rake::Task["federation:cleanup_duplicates"].invoke

    # Re-issue federation tokens for affected remote users
    if counts[:remote_users] > 0
      puts
      puts "Note: Federation tokens for updated remote users were issued by their home instances."
      puts "Tokens stored on THIS instance (as a remote/receiving instance) will remain valid"
      puts "until the remote users re-authenticate."
    end
  end

  desc "Remove duplicate federation references (keeps most recently updated record per composite key)"
  task cleanup_duplicates: :environment do
    total_removed = 0

    # RemoteServerReference: group by [user_id, remote_server_id]
    dupes = RemoteServerReference
      .select("user_id, remote_server_id")
      .group("user_id, remote_server_id")
      .having("COUNT(*) > 1")

    dupes.each do |group|
      records = RemoteServerReference
        .where(user_id: group.user_id, remote_server_id: group.remote_server_id)
        .order(updated_at: :desc)
      keep = records.first
      to_delete = records.where.not(id: keep.id)
      count = to_delete.count
      to_delete.destroy_all
      total_removed += count
    end
    puts "RemoteServerReference: removed #{total_removed} duplicates"

    conv_removed = 0
    dupes = RemoteConversationReference
      .select("user_id, remote_conversation_id")
      .group("user_id, remote_conversation_id")
      .having("COUNT(*) > 1")

    dupes.each do |group|
      records = RemoteConversationReference
        .where(user_id: group.user_id, remote_conversation_id: group.remote_conversation_id)
        .order(updated_at: :desc)
      keep = records.first
      to_delete = records.where.not(id: keep.id)
      count = to_delete.count
      to_delete.destroy_all
      conv_removed += count
    end
    puts "RemoteConversationReference: removed #{conv_removed} duplicates"
    total_removed += conv_removed

    friend_removed = 0
    dupes = RemoteFriendReference
      .select("user_id, friend_public_key")
      .group("user_id, friend_public_key")
      .having("COUNT(*) > 1")

    dupes.each do |group|
      records = RemoteFriendReference
        .where(user_id: group.user_id, friend_public_key: group.friend_public_key)
        .order(updated_at: :desc)
      keep = records.first
      to_delete = records.where.not(id: keep.id)
      count = to_delete.count
      to_delete.destroy_all
      friend_removed += count
    end
    puts "RemoteFriendReference: removed #{friend_removed} duplicates"
    total_removed += friend_removed

    # RemoteUser: verify no stale duplicates by nostr_public_key
    user_removed = 0
    dupes = RemoteUser
      .select("nostr_public_key")
      .group("nostr_public_key")
      .having("COUNT(*) > 1")

    dupes.each do |group|
      records = RemoteUser
        .where(nostr_public_key: group.nostr_public_key)
        .order(updated_at: :desc)
      keep = records.first
      to_delete = records.where.not(id: keep.id)
      count = to_delete.count
      to_delete.destroy_all
      user_removed += count
    end
    puts "RemoteUser: removed #{user_removed} duplicates"
    total_removed += user_removed

    puts
    puts "Total duplicates removed: #{total_removed}"
  end
end

def extract_bare_domain(url)
  uri = URI.parse(url)
  default = uri.scheme == "https" ? 443 : 80
  if uri.port == default
    uri.host
  else
    "#{uri.host}:#{uri.port}"
  end
rescue URI::InvalidURIError
  url
end
