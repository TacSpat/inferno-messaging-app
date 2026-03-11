FactoryBot.define do
  factory :call_participant do
    association :call
    association :user, factory: [ :user, :confirmed ]
    joined_at { Time.current }
  end
end
