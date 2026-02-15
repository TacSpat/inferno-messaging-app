FactoryBot.define do
  factory :channel do
    sequence(:name) { |n| "channel-#{n}" }
    channel_type { :text }
    association :server

    trait :shared do
      shared { true }
      nostr_group_id { "test-group-#{SecureRandom.hex(4)}" }
      nostr_relay_url { "wss://relay.example.com" }
    end
  end
end
