require 'rails_helper'

RSpec.describe ContentHash, type: :model do
  describe ".hamming_distance" do
    it "returns 0 for identical hashes" do
      expect(ContentHash.hamming_distance("abcdef01", "abcdef01")).to eq(0)
    end

    it "returns positive integer for different hashes" do
      distance = ContentHash.hamming_distance("00000000", "000000ff")
      expect(distance).to be > 0
    end

    it "returns Infinity for nil input" do
      expect(ContentHash.hamming_distance(nil, "abcdef01")).to eq(Float::INFINITY)
      expect(ContentHash.hamming_distance("abcdef01", nil)).to eq(Float::INFINITY)
    end
  end

  describe ".find_similar" do
    it "finds exact matches" do
      ch = create(:content_hash, hash_value: "abcdef01", hash_type: "dhash")
      result = ContentHash.find_similar("abcdef01", hash_type: "dhash")
      expect(result).to include(ch)
    end

    it "finds fuzzy matches within threshold" do
      create(:content_hash, hash_value: "abcdef01", hash_type: "dhash")
      # Same hash should match itself
      result = ContentHash.find_similar("abcdef01", hash_type: "dhash", threshold: 5)
      expect(result).not_to be_empty
    end

    it "returns empty for no match" do
      create(:content_hash, hash_value: "00000000", hash_type: "dhash")
      result = ContentHash.find_similar("ffffffff", hash_type: "dhash", threshold: 2)
      expect(result).to be_empty
    end
  end

  describe ".match?" do
    it "returns true when similar hash exists" do
      create(:content_hash, hash_value: "abcdef01", hash_type: "dhash")
      expect(ContentHash.match?("abcdef01")).to be true
    end

    it "returns false when no match" do
      expect(ContentHash.match?("nonexistent")).to be false
    end
  end

  describe "#allowlist!" do
    let(:content_hash) { create(:content_hash, hash_value: "abc123", hash_type: "dhash") }

    it "sets allowlisted to true" do
      allow(CsamHashEntry).to receive(:match?).and_return(false)
      content_hash.allowlist!
      expect(content_hash.reload.allowlisted).to be true
    end

    it "skips if CSAM match" do
      allow(CsamHashEntry).to receive(:match?).and_return(true)
      result = content_hash.allowlist!
      expect(result).to be false
      expect(content_hash.reload.allowlisted).to be false
    end
  end

  describe "#compute_confidence" do
    let(:content_hash) { create(:content_hash, hash_value: "abc123", source: "shared", reporter_pubkeys: pubkeys) }

    context "with friend pubkeys" do
      let(:pubkeys) { [ "friend_pk" ] }

      before do
        allow(Contact).to receive(:find_by).with(pubkey: "friend_pk").and_return(
          double(accepted?: true)
        )
      end

      it "weights friend at 1.0" do
        result = content_hash.compute_confidence
        expect(result).to eq(1.0)
      end
    end

    context "with known contact pubkeys" do
      let(:pubkeys) { [ "known_pk" ] }

      before do
        allow(Contact).to receive(:find_by).with(pubkey: "known_pk").and_return(
          double(accepted?: false)
        )
      end

      it "weights known contact at 0.3" do
        result = content_hash.compute_confidence
        expect(result).to eq(0.3)
      end
    end

    context "with unknown pubkeys" do
      let(:pubkeys) { [ "unknown_pk" ] }

      before do
        allow(Contact).to receive(:find_by).with(pubkey: "unknown_pk").and_return(nil)
      end

      it "weights unknown at 0.1" do
        result = content_hash.compute_confidence
        expect(result).to eq(0.1)
      end
    end
  end
end
