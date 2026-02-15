require 'rails_helper'

RSpec.describe Nip05Cache, type: :model do
  describe "validations" do
    subject { build(:nip05_cache) }

    it { should validate_presence_of(:identifier) }
    it { should validate_uniqueness_of(:identifier) }
    it { should validate_presence_of(:public_key) }
    it { should validate_presence_of(:verified_at) }
    it { should validate_presence_of(:expires_at) }
  end

  describe "#expired?" do
    it "returns true when expires_at is in the past" do
      cache = build(:nip05_cache, :expired)
      expect(cache.expired?).to be true
    end

    it "returns false when expires_at is in the future" do
      cache = build(:nip05_cache, expires_at: 1.hour.from_now)
      expect(cache.expired?).to be false
    end
  end

  describe ".lookup" do
    let(:pubkey) { SecureRandom.hex(32) }

    context "cache hit" do
      it "returns the cached public key" do
        create(:nip05_cache, identifier: "alice@example.com", public_key: pubkey)
        result = Nip05Cache.lookup("alice@example.com")
        expect(result).to eq(pubkey)
      end

      it "is case-insensitive" do
        create(:nip05_cache, identifier: "alice@example.com", public_key: pubkey)
        result = Nip05Cache.lookup("Alice@Example.com")
        expect(result).to eq(pubkey)
      end
    end

    context "expired cache" do
      it "fetches from remote and updates cache" do
        create(:nip05_cache, :expired, identifier: "alice@example.com", public_key: "old_key")

        stub_request(:get, "https://example.com/.well-known/nostr.json?name=alice")
          .to_return(
            status: 200,
            body: { names: { "alice" => pubkey } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = Nip05Cache.lookup("alice@example.com")
        expect(result).to eq(pubkey)
      end
    end

    context "cache miss" do
      it "fetches from remote and creates cache entry" do
        stub_request(:get, "https://example.com/.well-known/nostr.json?name=alice")
          .to_return(
            status: 200,
            body: { names: { "alice" => pubkey } }.to_json,
            headers: { "Content-Type" => "application/json" }
          )

        result = Nip05Cache.lookup("alice@example.com")
        expect(result).to eq(pubkey)
        expect(Nip05Cache.find_by(identifier: "alice@example.com")).to be_present
      end

      it "returns nil when remote returns no data" do
        stub_request(:get, "https://example.com/.well-known/nostr.json?name=alice")
          .to_return(status: 404)

        result = Nip05Cache.lookup("alice@example.com")
        expect(result).to be_nil
      end

      it "returns nil for invalid identifiers" do
        expect(Nip05Cache.lookup("invalid")).to be_nil
      end
    end
  end

  describe ".fetch_from_remote" do
    it "fetches and parses NIP-05 JSON" do
      pubkey = SecureRandom.hex(32)
      stub_request(:get, "https://example.com/.well-known/nostr.json?name=alice")
        .to_return(
          status: 200,
          body: { names: { "alice" => pubkey } }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      result = Nip05Cache.fetch_from_remote("alice", "example.com")
      expect(result).to eq(pubkey)
    end

    it "returns nil on HTTP error" do
      stub_request(:get, "https://example.com/.well-known/nostr.json?name=alice")
        .to_return(status: 500)

      result = Nip05Cache.fetch_from_remote("alice", "example.com")
      expect(result).to be_nil
    end

    it "returns nil on network error" do
      stub_request(:get, "https://example.com/.well-known/nostr.json?name=alice")
        .to_timeout

      result = Nip05Cache.fetch_from_remote("alice", "example.com")
      expect(result).to be_nil
    end
  end

  describe ".cleanup_expired" do
    it "removes expired entries" do
      valid = create(:nip05_cache, expires_at: 1.hour.from_now)
      expired = create(:nip05_cache, :expired)

      Nip05Cache.cleanup_expired

      expect(Nip05Cache.exists?(valid.id)).to be true
      expect(Nip05Cache.exists?(expired.id)).to be false
    end
  end
end
