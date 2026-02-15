FactoryBot.define do
  factory :nostr_event_log do
    sequence(:event_id) { |n| SecureRandom.hex(32) }
    kind { 9 }
    pubkey { SecureRandom.hex(32) }
    direction { "inbound" }
    event_created_at { Time.current }
    association :channel
  end
end
