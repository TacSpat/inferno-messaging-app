require 'rails_helper'

RSpec.describe "PaperTrail integration", type: :model do
  describe "InstanceConfig" do
    it "tracks changes to federation_mode" do
      config = InstanceConfig.current
      expect {
        config.update!(federation_mode: "closed")
      }.to change(PaperTrail::Version.where(item_type: "InstanceConfig"), :count).by(1)
    end

    it "tracks changes to lockdown fields" do
      config = InstanceConfig.current
      expect {
        config.update!(lockdown_enabled: true)
      }.to change(PaperTrail::Version.where(item_type: "InstanceConfig"), :count).by(1)
    end

    it "does not track changes to non-audited fields" do
      config = InstanceConfig.current
      expect {
        config.update!(instance_name: "New Name")
      }.not_to change(PaperTrail::Version.where(item_type: "InstanceConfig"), :count)
    end
  end

  describe "InstanceBlocklist" do
    it "tracks creation" do
      expect {
        create(:instance_blocklist)
      }.to change(PaperTrail::Version.where(item_type: "InstanceBlocklist"), :count)
    end

    it "tracks deletion" do
      blocklist = create(:instance_blocklist)
      expect {
        blocklist.destroy
      }.to change(PaperTrail::Version.where(item_type: "InstanceBlocklist"), :count).by(1)
    end
  end

  describe "ModerationReport" do
    it "tracks status changes" do
      report = create(:moderation_report)
      admin = create(:user, :confirmed, :admin)

      expect {
        report.review!(admin, new_status: "reviewed")
      }.to change(PaperTrail::Version.where(item_type: "ModerationReport"), :count).by(1)
    end

    it "does not track changes to non-audited fields" do
      report = create(:moderation_report)
      expect {
        report.update!(reason: "Updated reason")
      }.not_to change(PaperTrail::Version.where(item_type: "ModerationReport"), :count)
    end
  end

  describe "LegalHold" do
    it "tracks creation and lifting" do
      hold = nil
      expect {
        hold = create(:legal_hold)
      }.to change(PaperTrail::Version.where(item_type: "LegalHold"), :count)

      expect {
        hold.lift!
      }.to change(PaperTrail::Version.where(item_type: "LegalHold"), :count).by(1)
    end
  end

  describe "versions table metadata columns" do
    it "has remote_domain column" do
      expect(PaperTrail::Version.column_names).to include("remote_domain")
    end

    it "has ip_address column" do
      expect(PaperTrail::Version.column_names).to include("ip_address")
    end

    it "has metadata column" do
      expect(PaperTrail::Version.column_names).to include("metadata")
    end
  end
end
