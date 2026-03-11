FactoryBot.define do
  factory :block do
    association :blocker, factory: [ :user, :confirmed ]
    association :blocked, factory: [ :user, :confirmed ]
  end
end
