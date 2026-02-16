# Use a unique session cookie name per instance to prevent session conflicts
# when multiple instances share the same domain (e.g., localhost with different ports)
domain = ENV.fetch("INSTANCE_DOMAIN", "localhost").gsub(/[^a-zA-Z0-9]/, "_")
Rails.application.config.session_store :cookie_store, key: "_messaging_app_#{domain}_session"
