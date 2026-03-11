FactoryBot.define do
  factory :conversation do
    kind { :direct }

    trait :group do
      kind { :group_chat }
      sequence(:name) { |n| "Group Chat #{n}" }
    end
  end
end
