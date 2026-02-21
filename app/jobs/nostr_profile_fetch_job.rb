class NostrProfileFetchJob < ApplicationJob
  queue_as :default

  def perform(pubkey)
    NostrProfileResolver.resolve(pubkey)
  end
end
