namespace :maintenance do
  desc "Prune old messages and attachments based on InstanceConfig settings"
  task prune: :environment do
    PruneMessagesJob.perform_now
  end

  desc "Clean up expired auth challenges and NIP-05 cache entries"
  task cleanup_auth: :environment do
    challenges = NostrAuthChallenge.cleanup_expired
    caches = Nip05Cache.cleanup_expired
    puts "Cleaned up #{challenges} expired auth challenges and #{caches} expired NIP-05 cache entries"
  end
end
