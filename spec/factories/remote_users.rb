FactoryBot.define do
  factory :remote_user do
    sequence(:nostr_public_key) { |n| SecureRandom.hex(32) }
    home_instance { "remote.chat" }
    sequence(:username) { |n| "remote_user_#{n}" }
    display_name { username }
  end
end
