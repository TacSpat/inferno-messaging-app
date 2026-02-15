FactoryBot.define do
  factory :moderation_report do
    association :reporter, factory: [:user, :confirmed]
    reported_pubkey { SecureRandom.hex(32) }
    report_type { "spam" }
    reason { "Test report reason" }
    status { "open" }

    trait :reviewed do
      status { "reviewed" }
      association :reviewed_by, factory: [:user, :confirmed, :admin]
    end

    trait :actioned do
      status { "actioned" }
      association :reviewed_by, factory: [:user, :confirmed, :admin]
    end
  end
end
