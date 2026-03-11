FactoryBot.define do
  factory :call do
    association :conversation
    association :initiated_by, factory: [ :user, :confirmed ]
    status { "ringing" }
  end
end
