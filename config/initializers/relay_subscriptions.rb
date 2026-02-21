# Start persistent relay subscriptions after Rails boots.
# Only in server processes (not console, rake, etc.)
Rails.application.config.after_initialize do
  if defined?(Rails::Server) || (defined?(Puma) && Puma.respond_to?(:cli_config))
    Thread.new do
      sleep 3 # Wait for DB and relay connections to be ready
      begin
        if User.owner&.nostr_public_key.present? && RelayConnection.active.any?
          Rails.logger.info("[RelaySubscriptions] Starting RelaySubscriptionManager...")
          RelaySubscriptionManager.instance.start
        else
          Rails.logger.info("[RelaySubscriptions] Skipping — no user or relays configured yet")
        end
      rescue => e
        Rails.logger.error("[RelaySubscriptions] Failed to start: #{e.message}")
      end
    end
  end
end
