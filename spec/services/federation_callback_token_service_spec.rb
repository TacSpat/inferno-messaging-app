require 'rails_helper'

RSpec.describe FederationCallbackTokenService do
  include ActiveSupport::Testing::TimeHelpers

  let(:from_pubkey) { SecureRandom.hex(32) }
  let(:to_pubkey) { SecureRandom.hex(32) }

  describe ".generate" do
    it "returns a non-empty string token" do
      token = described_class.generate(from_pubkey: from_pubkey, to_pubkey: to_pubkey)
      expect(token).to be_a(String)
      expect(token).not_to be_empty
    end
  end

  describe ".verify" do
    it "returns the payload for a valid token" do
      token = described_class.generate(from_pubkey: from_pubkey, to_pubkey: to_pubkey)
      payload = described_class.verify(token)

      expect(payload).to be_present
      expect(payload[:from_pubkey]).to eq(from_pubkey)
      expect(payload[:to_pubkey]).to eq(to_pubkey)
      expect(payload[:issued_at]).to be_present
    end

    it "returns nil for an invalid token" do
      expect(described_class.verify("garbage")).to be_nil
    end

    it "returns nil for an expired token" do
      token = described_class.generate(from_pubkey: from_pubkey, to_pubkey: to_pubkey)
      travel 31.days do
        expect(described_class.verify(token)).to be_nil
      end
    end

    it "returns payload for a token within 30 days" do
      token = described_class.generate(from_pubkey: from_pubkey, to_pubkey: to_pubkey)
      travel 29.days do
        expect(described_class.verify(token)).to be_present
      end
    end
  end
end
