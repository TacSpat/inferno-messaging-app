FactoryBot.define do
  factory :remote_server_reference do
    association :user, factory: [ :user, :confirmed ]
    sequence(:remote_instance_url) { |n| "https://instance#{n}.chat" }
    sequence(:remote_server_id) { |n| "srv_#{SecureRandom.hex(8)}" }
    sequence(:name) { |n| "Remote Server #{n}" }
    invite_code { SecureRandom.alphanumeric(8) }
    position { 0 }
  end
end
