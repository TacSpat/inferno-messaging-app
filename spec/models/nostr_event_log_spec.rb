require 'rails_helper'

RSpec.describe NostrEventLog, type: :model do
  describe "validations" do
    subject { build(:nostr_event_log) }

    it { should validate_presence_of(:event_id) }
    it { should validate_uniqueness_of(:event_id) }
    it { should validate_presence_of(:kind) }
    it { should validate_presence_of(:pubkey) }
    it { should validate_presence_of(:direction) }
    it { should validate_inclusion_of(:direction).in_array(NostrEventLog::DIRECTIONS) }
  end

  describe "associations" do
    it { should belong_to(:message).optional }
    it { should belong_to(:channel).optional }
  end

  describe ".already_processed?" do
    it "returns true when an event with that ID exists" do
      log = create(:nostr_event_log, event_id: "abc123")
      expect(NostrEventLog.already_processed?("abc123")).to be true
    end

    it "returns false when no event with that ID exists" do
      expect(NostrEventLog.already_processed?("nonexistent")).to be false
    end
  end

  describe "scopes" do
    let!(:inbound) { create(:nostr_event_log, direction: "inbound") }
    let!(:outbound) { create(:nostr_event_log, direction: "outbound") }

    it ".inbound returns only inbound events" do
      expect(NostrEventLog.inbound).to contain_exactly(inbound)
    end

    it ".outbound returns only outbound events" do
      expect(NostrEventLog.outbound).to contain_exactly(outbound)
    end
  end
end
