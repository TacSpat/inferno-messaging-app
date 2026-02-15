FactoryBot.define do
  factory :instance_config do
    instance_name { "Test Instance" }
    federation_mode { "open" }
    lockdown_enabled { false }
  end
end
