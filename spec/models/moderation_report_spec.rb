require 'rails_helper'

RSpec.describe ModerationReport, type: :model do
  describe "validations" do
    it { should validate_presence_of(:reported_pubkey) }
    it { should validate_presence_of(:report_type) }
    it { should validate_inclusion_of(:report_type).in_array(ModerationReport::REPORT_TYPES) }
    it { should validate_presence_of(:status) }
    it { should validate_inclusion_of(:status).in_array(ModerationReport::STATUSES) }
  end

  describe "associations" do
    it { should belong_to(:reporter).class_name("User") }
    it { should belong_to(:reviewed_by).class_name("User").optional }
  end

  describe "#review!" do
    it "updates status and reviewed_by" do
      report = create(:moderation_report)
      admin = create(:user, :confirmed, :admin)

      report.review!(admin, new_status: "reviewed")

      expect(report.status).to eq("reviewed")
      expect(report.reviewed_by).to eq(admin)
    end
  end

  describe "scopes" do
    let!(:open_report) { create(:moderation_report, status: "open") }
    let!(:reviewed_report) { create(:moderation_report, :reviewed) }
    let!(:actioned_report) { create(:moderation_report, :actioned) }

    it ".open_reports returns only open reports" do
      expect(ModerationReport.open_reports).to contain_exactly(open_report)
    end

    it ".resolved returns reviewed, dismissed, and actioned reports" do
      expect(ModerationReport.resolved).to contain_exactly(reviewed_report, actioned_report)
    end

    it ".by_pubkey filters by pubkey" do
      target_pubkey = open_report.reported_pubkey
      expect(ModerationReport.by_pubkey(target_pubkey)).to contain_exactly(open_report)
    end
  end

  describe "#open?" do
    it "returns true for open status" do
      expect(build(:moderation_report, status: "open").open?).to be true
    end

    it "returns false for other statuses" do
      expect(build(:moderation_report, status: "reviewed").open?).to be false
    end
  end

  describe "#resolved?" do
    it "returns true for reviewed, dismissed, actioned" do
      %w[reviewed dismissed actioned].each do |status|
        expect(build(:moderation_report, status: status).resolved?).to be true
      end
    end

    it "returns false for open" do
      expect(build(:moderation_report, status: "open").resolved?).to be false
    end
  end

  describe "#reported_remote_user" do
    it "finds the remote user by pubkey" do
      remote_user = create(:remote_user)
      report = build(:moderation_report, reported_pubkey: remote_user.nostr_public_key)
      expect(report.reported_remote_user).to eq(remote_user)
    end

    it "returns nil when no remote user exists" do
      report = build(:moderation_report, reported_pubkey: "nonexistent")
      expect(report.reported_remote_user).to be_nil
    end
  end

  describe "#reported_user" do
    it "finds the local user by pubkey" do
      user = create(:user, :confirmed, nostr_public_key: "abc123def")
      report = build(:moderation_report, reported_pubkey: "abc123def")
      expect(report.reported_user).to eq(user)
    end

    it "returns nil when no local user exists" do
      report = build(:moderation_report, reported_pubkey: "nonexistent")
      expect(report.reported_user).to be_nil
    end
  end
end
