FactoryBot.define do
  factory :data_export do
    association :user, factory: [ :user, :confirmed ]
    association :requested_by, factory: [ :user, :confirmed, :admin ]
    export_type { "full" }
    status { "pending" }
  end
end
