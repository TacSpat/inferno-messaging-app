FactoryBot.define do
  factory :user_suspension do
    association :user, factory: [ :user, :confirmed ]
    association :suspended_by, factory: [ :user, :confirmed, :admin ]
    suspension_type { "permanent" }
    reason { "Violation of terms of service" }
    reason_category { "admin_action" }

    trait :temporary do
      suspension_type { "temporary" }
      expires_at { 7.days.from_now }
    end

    trait :expired do
      suspension_type { "temporary" }
      expires_at { 1.hour.ago }
    end

    trait :lifted do
      lifted_at { Time.current }
      association :lifted_by, factory: [ :user, :confirmed, :admin ]
      lift_reason { "Appeal approved" }
    end

    trait :auto do
      auto_triggered { true }
      suspended_by { nil }
    end
  end
end
