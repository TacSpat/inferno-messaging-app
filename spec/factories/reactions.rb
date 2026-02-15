FactoryBot.define do
  factory :reaction do
    emoji { "\u{1F44D}" }
    association :user, factory: [:user, :confirmed]
    association :message
  end
end
