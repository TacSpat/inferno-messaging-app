FactoryBot.define do
  factory :user do
    sequence(:username) { |n| "testuser#{n}" }
    sequence(:email) { |n| "test#{n}@example.com" }
    password { "password123" }
    display_name { username }

    trait :confirmed do
      confirmed_at { Time.current }
    end

    trait :admin do
      instance_admin { true }
    end

    trait :remote do
      remote { true }
      association :remote_user_detail, factory: :remote_user
      after(:build) do |user|
        user.skip_confirmation!
      end
    end

    # Let the model's after_create callback generate real nostr keypairs
    # To skip keypair generation, pass nostr_public_key: "some_hex" explicitly
  end
end
