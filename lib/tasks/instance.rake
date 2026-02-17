namespace :instance do
  desc "Apply config/instance.yml + ENV settings to the database (InstanceConfig + RelayConnections)"
  task configure: :environment do
    config_path = Rails.root.join("config", "instance.yml")
    env_config = {}

    if config_path.exist?
      raw = ERB.new(config_path.read).result
      all_config = YAML.safe_load(raw, permitted_classes: [ Symbol ], aliases: true) || {}
      env_config = all_config[Rails.env] || all_config["default"] || {}
    end

    # ENV vars override YAML values (sensitive + production values live in .env only)
    env_config["instance_relay_url"] = ENV["INSTANCE_RELAY_URL"] if ENV["INSTANCE_RELAY_URL"].present?

    if ENV["RELAY_CONNECTIONS"].present?
      env_config["relay_connections"] = ENV["RELAY_CONNECTIONS"].split(",").map(&:strip)
    end

    # --- Apply InstanceConfig settings ---
    ic = InstanceConfig.current
    db_attrs = {}

    %w[
      instance_name instance_description instance_relay_url federation_mode
      max_users max_servers max_servers_per_user max_channels_per_server
      max_categories_per_server max_members_per_server max_roles_per_server
      max_upload_size_mb max_storage_per_user_mb
      voice_enabled max_voice_participants_per_channel
      pruning_strategy message_retention_days attachment_retention_days
      keep_pinned_messages
    ].each do |key|
      value = env_config[key]
      next if value.nil? || (value.is_a?(String) && value.blank?)
      db_attrs[key] = value
    end

    if db_attrs.any?
      ic.update!(db_attrs)
      puts "InstanceConfig updated: #{db_attrs.keys.join(', ')}"
    else
      puts "InstanceConfig: no changes."
    end

    # --- Apply RelayConnections ---
    relay_urls = env_config["relay_connections"] || []
    relay_urls = Array(relay_urls).reject(&:blank?)

    if relay_urls.any?
      existing = RelayConnection.pluck(:url)
      added = 0
      relay_urls.each do |url|
        unless existing.include?(url)
          RelayConnection.create!(url: url, status: "active")
          added += 1
        end
      end
      puts "RelayConnections: #{added} added, #{existing.size} already existed."
    else
      puts "RelayConnections: none configured."
    end

    puts "Done. Instance configured for #{Rails.env}."
  end
end
