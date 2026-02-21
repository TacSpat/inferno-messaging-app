FactoryBot.define do
  factory :contact do
    pubkey { "MyString" }
    relay_url { "MyString" }
    petname { "MyString" }
    display_name { "MyString" }
    avatar_url { "MyString" }
    bio { "MyText" }
    last_seen_at { "2026-02-20 16:08:36" }
    friendship_status { 1 }
  end
end
