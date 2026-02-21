# frozen_string_literal: true

# Desktop packaging support: when INFERNO_DATA_DIR is set, redirect all writable
# paths (storage, tmp, log) outside the read-only Tebako filesystem.
#
# Platform defaults (set by launcher scripts):
#   Linux:   ~/.local/share/inferno/
#   macOS:   ~/Library/Application Support/Inferno/
#   Windows: %APPDATA%\Inferno\

if (data_dir = ENV["INFERNO_DATA_DIR"]).present?
  data_path = Pathname.new(data_dir)

  # Ensure directories exist
  %w[storage storage/db tmp log tmp/pids tmp/cache].each do |sub|
    FileUtils.mkdir_p(data_path.join(sub))
  end

  # SQLite databases
  Rails.application.config.after_initialize do
    # Rewrite database paths for all SQLite databases
    ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).each do |db_config|
      next unless db_config.adapter == "sqlite3"

      original = db_config.database
      next if original == ":memory:"

      basename = File.basename(original)
      new_path = data_path.join("storage", "db", basename).to_s

      # Copy the DB from the app bundle on first run
      if !File.exist?(new_path) && File.exist?(original)
        FileUtils.cp(original, new_path)
      end
    end
  end

  # Override database.yml paths via DATABASE_URL-style env vars
  db_dir = data_path.join("storage", "db")
  ENV["PRIMARY_DATABASE_PATH"]  ||= db_dir.join("production.sqlite3").to_s
  ENV["CACHE_DATABASE_PATH"]    ||= db_dir.join("production_cache.sqlite3").to_s
  ENV["QUEUE_DATABASE_PATH"]    ||= db_dir.join("production_queue.sqlite3").to_s
  ENV["CABLE_DATABASE_PATH"]    ||= db_dir.join("production_cable.sqlite3").to_s

  # Active Storage
  Rails.application.config.active_storage.service_configurations ||= {}

  # Tmp and log
  Rails.application.config.paths["tmp"] = data_path.join("tmp").to_s
  Rails.application.config.paths["log"] = data_path.join("log").to_s

  ENV["PIDFILE"] ||= data_path.join("tmp", "pids", "server.pid").to_s

  Rails.logger&.info "[Desktop] Data directory: #{data_dir}" if defined?(Rails.logger) && Rails.logger
end
