FactoryBot.define do
  factory :invite do
    association :server
    association :creator, factory: [:user, :confirmed]
    active { true }
  end
end
