FactoryBot.define do
  factory :content_hash do
    hash_value { SecureRandom.hex(8) }
    hash_type { "dhash" }
    source { "local" }
  end
end
