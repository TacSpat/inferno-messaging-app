FactoryBot.define do
  factory :csam_hash_entry do
    hash_value { SecureRandom.hex(8) }
    hash_type { "dhash" }
    list_source { "test" }
    added_at { Time.current }
  end
end
