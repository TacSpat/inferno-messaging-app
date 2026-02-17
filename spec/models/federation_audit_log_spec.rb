require 'rails_helper'

RSpec.describe FederationAuditLog, type: :model do
  describe "validations" do
    it { should validate_presence_of(:event_type) }
    it { should validate_inclusion_of(:event_type).in_array(FederationAuditLog::EVENT_TYPES) }
  end

  describe "associations" do
    it { should belong_to(:actor).optional }
    it { should belong_to(:target).optional }
  end

  describe "EVENT_TYPES" do
    it "includes all expected event types" do
      expected = %w[auth_attempt auth_success auth_failure token_issued
                    domain_block domain_unblock lockdown_activated
                    lockdown_lifted moderation_report_reviewed
                    user_suspended user_suspension_lifted]
      expect(FederationAuditLog::EVENT_TYPES).to match_array(expected)
    end
  end

  describe "#readonly?" do
    it "returns false for new records" do
      log = build(:federation_audit_log)
      expect(log.readonly?).to be false
    end

    it "returns true for persisted records" do
      log = create(:federation_audit_log)
      expect(log.readonly?).to be true
    end

    it "prevents updates to persisted records" do
      log = create(:federation_audit_log)
      expect { log.update!(remote_domain: "changed.com") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "prevents destruction of persisted records" do
      log = create(:federation_audit_log)
      expect { log.destroy! }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe "scopes" do
    let!(:auth_log) { create(:federation_audit_log, event_type: "auth_attempt", remote_domain: "a.com") }
    let!(:block_log) { create(:federation_audit_log, :domain_block, remote_domain: "b.com") }

    describe ".by_event" do
      it "filters by event type" do
        expect(described_class.by_event("auth_attempt")).to include(auth_log)
        expect(described_class.by_event("auth_attempt")).not_to include(block_log)
      end
    end

    describe ".by_domain" do
      it "filters by remote domain" do
        expect(described_class.by_domain("a.com")).to include(auth_log)
        expect(described_class.by_domain("a.com")).not_to include(block_log)
      end
    end

    describe ".recent" do
      it "returns records ordered by created_at desc" do
        results = described_class.recent(10)
        expect(results.first.created_at).to be >= results.last.created_at
      end
    end

    describe ".in_range" do
      it "returns records within the time range" do
        results = described_class.in_range(1.hour.ago, 1.hour.from_now)
        expect(results).to include(auth_log, block_log)
      end

      it "excludes records outside the range" do
        results = described_class.in_range(2.days.ago, 1.day.ago)
        expect(results).to be_empty
      end
    end
  end

  describe "polymorphic actor" do
    it "accepts a User as actor" do
      user = create(:user, :confirmed)
      log = create(:federation_audit_log, :auth_success, actor: user)
      expect(log.actor).to eq(user)
      expect(log.actor_type).to eq("User")
    end
  end
end
