FactoryBot.define do
  factory :relay_connection do
    sequence(:url) { |n| "wss://relay#{n}.example.com" }
    status { "active" }

    trait :disabled do
      status { "disabled" }
    end

    trait :error do
      status { "error" }
      last_error_at { Time.current }
      last_error_message { "Connection refused" }
    end
  end
end
