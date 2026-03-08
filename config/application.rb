require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module MessagingApp
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.0

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Use Solid Queue for background jobs
    config.active_job.queue_adapter = :solid_queue

    # Serve attachments via proxy (inline) instead of redirect so browsers can cache them
    config.active_storage.resolve_model_to_route = :rails_storage_proxy

    # Domain used for federation addresses and relay URL derivation.
    # Load from ENV (set by foreman via .env), or fall back to reading .env directly.
    config.x.instance_domain = ENV.fetch("INSTANCE_DOMAIN") {
      env_file = File.expand_path("../../.env", __FILE__)
      if File.exist?(env_file)
        match = File.read(env_file).match(/^INSTANCE_DOMAIN=(.+)/)
        match ? match[1].strip : "localhost"
      else
        "localhost"
      end
    }

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
