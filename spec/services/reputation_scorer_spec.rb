require 'rails_helper'

RSpec.describe ReputationScorer do
  let(:pubkey) { "test_pubkey_hex" }

  describe "#score" do
    context "with no signals" do
      it "returns base score of 100" do
        scorer = described_class.new(pubkey)
        expect(scorer.score).to eq(100)
      end
    end

    context "with friend contact" do
      before do
        Contact.create!(pubkey: pubkey, friendship_status: :accepted)
      end

      it "adds +20 friend bonus and +5 known bonus" do
        scorer = described_class.new(pubkey)
        expect(scorer.score).to eq(100) # 100 + 25 = 125, clamped to 100
        expect(scorer.breakdown[:bonuses]).to eq(25)
      end
    end

    context "with known (non-friend) contact" do
      before do
        Contact.create!(pubkey: pubkey, friendship_status: :not_friend)
      end

      it "adds +5 known bonus" do
        scorer = described_class.new(pubkey)
        expect(scorer.breakdown[:bonuses]).to eq(5)
      end
    end

    context "with own hides" do
      before do
        3.times do
          msg = create(:message, nostr_author_pubkey: pubkey)
          msg.update_columns(hidden_at: Time.current, hidden_reason: "test")
        end
      end

      it "applies -15 per hide, capped at -45" do
        scorer = described_class.new(pubkey)
        expect(scorer.breakdown[:own_hide_penalty]).to eq(-45)
        expect(scorer.score).to eq(55) # 100 - 45
      end
    end

    context "with reports" do
      before do
        Contact.create!(pubkey: pubkey, report_count: 5)
      end

      it "applies -3 per report" do
        scorer = described_class.new(pubkey)
        expect(scorer.breakdown[:report_penalty]).to eq(-15)
      end
    end

    context "with sensitivity multiplier" do
      before do
        2.times do
          msg = create(:message, nostr_author_pubkey: pubkey)
          msg.update_columns(hidden_at: Time.current, hidden_reason: "test")
        end
      end

      it "relaxed halves penalties" do
        scorer = described_class.new(pubkey, sensitivity: "relaxed")
        # 2 hides = -30 raw, * 0.5 = -15
        expect(scorer.score).to eq(85)
      end

      it "strict multiplies penalties by 1.5" do
        scorer = described_class.new(pubkey, sensitivity: "strict")
        # 2 hides = -30 raw, * 1.5 = -45
        expect(scorer.score).to eq(55)
      end
    end

    it "clamps score between 0 and 100" do
      # Create enough negative signals to go below 0
      10.times do
        msg = create(:message, nostr_author_pubkey: pubkey)
        msg.update_columns(hidden_at: Time.current, hidden_reason: "test")
      end
      Contact.create!(pubkey: pubkey, report_count: 15)

      scorer = described_class.new(pubkey, sensitivity: "strict")
      expect(scorer.score).to be >= 0
      expect(scorer.score).to be <= 100
    end
  end
end
