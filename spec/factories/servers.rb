FactoryBot.define do
  factory :server do
    sequence(:name) { |n| "Test Server #{n}" }
    association :owner, factory: [ :user, :confirmed ]
  end
end
