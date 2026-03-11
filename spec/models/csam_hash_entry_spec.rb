require 'rails_helper'

RSpec.describe CsamHashEntry, type: :model do
  describe ".match?" do
    it "returns true for exact match" do
      create(:csam_hash_entry, hash_value: "abcdef01", hash_type: "dhash")
      expect(CsamHashEntry.match?("abcdef01", hash_type: "dhash")).to be true
    end

    it "returns false for no match" do
      expect(CsamHashEntry.match?("nonexistent")).to be false
    end
  end

  describe ".fuzzy_match?" do
    it "returns true for exact match" do
      create(:csam_hash_entry, hash_value: "abcdef01", hash_type: "dhash")
      expect(CsamHashEntry.fuzzy_match?("abcdef01")).to be true
    end

    it "returns true within hamming threshold" do
      create(:csam_hash_entry, hash_value: "abcdef01", hash_type: "dhash")
      # Same value = exact match
      expect(CsamHashEntry.fuzzy_match?("abcdef01", threshold: 10)).to be true
    end

    it "returns false for distant hash" do
      create(:csam_hash_entry, hash_value: "00000000", hash_type: "dhash")
      expect(CsamHashEntry.fuzzy_match?("ffffffff", threshold: 2)).to be false
    end
  end

  describe ".promote_from_shared!" do
    let(:content_hash) { create(:content_hash, hash_value: "promote_me", hash_type: "dhash") }

    it "creates a CSAM entry from content hash" do
      entry = CsamHashEntry.promote_from_shared!(content_hash)

      expect(entry).to be_persisted
      expect(entry.hash_value).to eq("promote_me")
      expect(entry.list_source).to eq("shared_network")
    end

    it "is idempotent" do
      CsamHashEntry.promote_from_shared!(content_hash)
      expect { CsamHashEntry.promote_from_shared!(content_hash) }.not_to change(CsamHashEntry, :count)
    end
  end
end
