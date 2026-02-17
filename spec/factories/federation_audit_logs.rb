FactoryBot.define do
  factory :federation_audit_log do
    event_type { "auth_attempt" }
    remote_domain { "remote.example.com" }
    ip_address { "127.0.0.1" }
    metadata { {} }

    trait :auth_success do
      event_type { "auth_success" }
    end

    trait :auth_failure do
      event_type { "auth_failure" }
    end

    trait :domain_block do
      event_type { "domain_block" }
    end

    trait :with_actor do
      association :actor, factory: [ :user, :confirmed ]
    end
  end
end
