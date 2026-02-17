FactoryBot.define do
  factory :message do
    content { "Hello, world!" }
    association :user, factory: [ :user, :confirmed ]
    association :channel
    public_id { SecureRandom.alphanumeric(12) }

    trait :in_shared_channel do
      association :channel, factory: [ :channel, :shared ]
    end
  end
end
