require 'cucumber/rails'
require 'webmock/cucumber'
require 'factory_bot'

ActionController::Base.allow_rescue = false

# DatabaseCleaner config
DatabaseCleaner.strategy = :truncation

Before do
  DatabaseCleaner.start
  InstanceConfig.first_or_create!

  # Stub relay services using class-level method replacement
  RelayService.define_singleton_method(:publish_to_all_original, RelayService.method(:publish_to_all)) rescue nil
  RelayService.define_singleton_method(:publish_to_all) { |*_args| {} }
  RelayService.define_singleton_method(:publish_to_relay) { |*_args| { success: true, message: "OK" } }
  RelayService.define_singleton_method(:fetch_from_all) { |*_args| [] }
  RelayService.define_singleton_method(:fetch_from_relay) { |*_args| [] }

  WebMock.disable_net_connect!(allow_localhost: true)
end

After do
  DatabaseCleaner.clean
end

World(FactoryBot::Syntax::Methods)

Cucumber::Rails::Database.javascript_strategy = :truncation

# Capybara config
Capybara.default_driver = :rack_test
Capybara.app_host = nil
