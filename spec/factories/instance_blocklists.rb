FactoryBot.define do
  factory :instance_blocklist do
    sequence(:domain) { |n| "blocked#{n}.example.com" }
    reason { "Test block" }
    association :blocked_by, factory: [ :user, :confirmed, :admin ]
    blocked_at { Time.current }
  end
end
