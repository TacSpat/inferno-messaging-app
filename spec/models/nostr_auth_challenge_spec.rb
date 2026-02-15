require 'rails_helper'

RSpec.describe NostrAuthChallenge, type: :model do
  describe "validations" do
    subject { build(:nostr_auth_challenge) }

    it { should validate_presence_of(:nonce) }
    it { should validate_uniqueness_of(:nonce) }
    it { should validate_presence_of(:requesting_domain) }
    it { should validate_presence_of(:callback_url) }
    it { should validate_presence_of(:expires_at) }
  end

  describe ".valid_for_nonce" do
    it "returns unexpired, unused challenges matching the nonce" do
      challenge = create(:nostr_auth_challenge)
      result = NostrAuthChallenge.valid_for_nonce(challenge.nonce)
      expect(result).to include(challenge)
    end

    it "excludes expired challenges" do
      challenge = create(:nostr_auth_challenge, expires_at: 1.minute.ago)
      result = NostrAuthChallenge.valid_for_nonce(challenge.nonce)
      expect(result).to be_empty
    end

    it "excludes used challenges" do
      challenge = create(:nostr_auth_challenge, used: true)
      result = NostrAuthChallenge.valid_for_nonce(challenge.nonce)
      expect(result).to be_empty
    end

    it "excludes challenges with different nonce" do
      create(:nostr_auth_challenge, nonce: "abc123")
      result = NostrAuthChallenge.valid_for_nonce("different_nonce")
      expect(result).to be_empty
    end
  end

  describe "#expired?" do
    it "returns true when expires_at is in the past" do
      challenge = build(:nostr_auth_challenge, expires_at: 1.minute.ago)
      expect(challenge.expired?).to be true
    end

    it "returns false when expires_at is in the future" do
      challenge = build(:nostr_auth_challenge, expires_at: 5.minutes.from_now)
      expect(challenge.expired?).to be false
    end
  end

  describe "#consume!" do
    it "marks the challenge as used" do
      challenge = create(:nostr_auth_challenge)
      challenge.consume!
      expect(challenge.reload.used).to be true
    end
  end

  describe ".cleanup_expired" do
    it "removes expired and used challenges" do
      _active = create(:nostr_auth_challenge, expires_at: 5.minutes.from_now)
      expired = create(:nostr_auth_challenge, expires_at: 2.hours.ago)
      used = create(:nostr_auth_challenge, used: true, expires_at: 2.hours.ago)

      NostrAuthChallenge.cleanup_expired

      expect(NostrAuthChallenge.exists?(expired.id)).to be false
      expect(NostrAuthChallenge.exists?(used.id)).to be false
      expect(NostrAuthChallenge.exists?(_active.id)).to be true
    end
  end
end
