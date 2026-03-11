require 'rails_helper'

RSpec.describe LocalConfig, type: :model do
  describe ".current" do
    it "creates a record on first call" do
      expect { LocalConfig.current }.to change(LocalConfig, :count).by(1)
    end

    it "returns the same record on subsequent calls" do
      first = LocalConfig.current
      second = LocalConfig.current
      expect(first.id).to eq(second.id)
    end
  end

  describe "#apply_protection_level!" do
    let(:config) { LocalConfig.current }

    context "standard" do
      it "sets strict safety values" do
        config.apply_protection_level!("standard")
        config.reload

        expect(config.safety_protection_level).to eq("standard")
        expect(config.safety_hide_unknown_senders).to be true
        expect(config.safety_block_links).to be true
        expect(config.safety_reputation_enabled).to be true
      end
    end

    context "relaxed" do
      it "sets relaxed safety values" do
        config.apply_protection_level!("relaxed")
        config.reload

        expect(config.safety_protection_level).to eq("relaxed")
        expect(config.safety_hide_unknown_senders).to be false
        expect(config.safety_block_links).to be false
        expect(config.safety_reputation_enabled).to be false
      end
    end
  end

  describe "#pruning_enabled?" do
    it "returns false for none" do
      config = LocalConfig.current
      config.update!(pruning_strategy: "none")
      expect(config.pruning_enabled?).to be false
    end

    it "returns true for time_based" do
      config = LocalConfig.current
      config.update!(pruning_strategy: "time_based")
      expect(config.pruning_enabled?).to be true
    end

    it "returns true for storage_based" do
      config = LocalConfig.current
      config.update!(pruning_strategy: "storage_based")
      expect(config.pruning_enabled?).to be true
    end
  end

  describe "validations" do
    it { is_expected.to validate_numericality_of(:max_channels_per_server).only_integer.is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:max_cache_size_mb).only_integer.is_greater_than_or_equal_to(0) }
    it { is_expected.to validate_numericality_of(:message_retention_days).only_integer.is_greater_than_or_equal_to(0) }
  end
end
