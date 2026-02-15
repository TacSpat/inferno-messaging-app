FactoryBot.define do
  factory :nip05_cache do
    sequence(:identifier) { |n| "user#{n}@example.com" }
    public_key { SecureRandom.hex(32) }
    verified_at { Time.current }
    expires_at { 24.hours.from_now }

    trait :expired do
      expires_at { 1.hour.ago }
    end
  end
end
