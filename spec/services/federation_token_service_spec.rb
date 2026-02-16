require 'rails_helper'

RSpec.describe FederationTokenService do
  include ActiveSupport::Testing::TimeHelpers

  let(:pubkey) { SecureRandom.hex(32) }
  let(:instance) { "remote.chat" }

  describe ".generate" do
    it "returns a non-empty string token" do
      token = described_class.generate(pubkey: pubkey, requesting_instance: instance)
      expect(token).to be_a(String)
      expect(token.length).to be > 10
    end

    it "generates different tokens for different pubkeys" do
      token1 = described_class.generate(pubkey: pubkey, requesting_instance: instance)
      token2 = described_class.generate(pubkey: SecureRandom.hex(32), requesting_instance: instance)
      expect(token1).not_to eq(token2)
    end
  end

  describe ".verify" do
    it "returns the payload for a valid token" do
      token = described_class.generate(pubkey: pubkey, requesting_instance: instance)
      payload = described_class.verify(token)

      expect(payload).to be_present
      expect(payload["pubkey"]).to eq(pubkey)
      expect(payload["instance"]).to eq(instance)
      expect(payload["issued_at"]).to be_a(Integer)
    end

    it "returns nil for a tampered token" do
      token = described_class.generate(pubkey: pubkey, requesting_instance: instance)
      tampered = token + "x"
      expect(described_class.verify(tampered)).to be_nil
    end

    it "returns nil for a garbage string" do
      expect(described_class.verify("not-a-real-token")).to be_nil
    end

    it "returns nil for an expired token" do
      token = described_class.generate(pubkey: pubkey, requesting_instance: instance)

      travel 31.days do
        expect(described_class.verify(token)).to be_nil
      end
    end

    it "returns payload for a token within the expiry window" do
      token = described_class.generate(pubkey: pubkey, requesting_instance: instance)

      travel 29.days do
        expect(described_class.verify(token)).to be_present
      end
    end
  end
end
