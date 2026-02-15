FactoryBot.define do
  factory :nostr_auth_challenge do
    nonce { SecureRandom.hex(32) }
    requesting_domain { "remote.chat" }
    callback_url { "https://remote.chat/auth/nostr/callback" }
    expires_at { 5.minutes.from_now }
    used { false }
  end
end
