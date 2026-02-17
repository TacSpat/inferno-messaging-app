FactoryBot.define do
  factory :legal_hold do
    association :holdable, factory: [ :user, :confirmed ]
    association :placed_by, factory: [ :user, :confirmed, :admin ]
    placed_at { Time.current }
    active { true }
    reason { "Legal preservation request" }

    trait :on_server do
      association :holdable, factory: :server
    end

    trait :on_channel do
      association :holdable, factory: :channel
    end

    trait :lifted do
      active { false }
      lifted_at { Time.current }
    end
  end
end
