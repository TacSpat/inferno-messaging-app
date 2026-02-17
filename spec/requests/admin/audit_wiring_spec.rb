require 'rails_helper'

RSpec.describe "Controller audit wiring", type: :request do
  describe "Admin::InstanceBlocklistsController" do
    let(:admin) { sign_in_as_admin }

    before { admin }

    it "logs domain_block on create" do
      expect {
        post admin_instance_blocklists_path, params: {
          domain: "evil.example.com",
          reason: "Spam"
        }
      }.to change { FederationAuditLog.where(event_type: "domain_block").count }.by(1)

      log = FederationAuditLog.last
      expect(log.remote_domain).to eq("evil.example.com")
      expect(log.actor).to eq(admin)
      expect(log.metadata["reason"]).to eq("Spam")
    end

    it "logs domain_unblock on destroy" do
      blocklist = create(:instance_blocklist, domain: "evil.example.com")

      expect {
        delete admin_instance_blocklist_path(blocklist)
      }.to change { FederationAuditLog.where(event_type: "domain_unblock").count }.by(1)

      log = FederationAuditLog.last
      expect(log.remote_domain).to eq("evil.example.com")
    end
  end

  describe "Admin::InstanceConfigsController" do
    before { sign_in_as_admin }

    it "logs lockdown_activated on emergency lockdown" do
      expect {
        post emergency_lockdown_admin_instance_config_path
      }.to change { FederationAuditLog.where(event_type: "lockdown_activated").count }.by(1)
    end

    it "logs lockdown_lifted on lift lockdown" do
      InstanceConfig.current.emergency_lockdown!

      expect {
        post lift_lockdown_admin_instance_config_path
      }.to change { FederationAuditLog.where(event_type: "lockdown_lifted").count }.by(1)
    end
  end

  describe "Admin::ModerationReportsController" do
    let(:admin) { sign_in_as_admin }
    let(:report) { create(:moderation_report) }

    before { admin }

    it "logs moderation_report_reviewed on review" do
      expect {
        post review_admin_moderation_report_path(report), params: { status: "reviewed" }
      }.to change { FederationAuditLog.where(event_type: "moderation_report_reviewed").count }.by(1)

      log = FederationAuditLog.last
      expect(log.actor).to eq(admin)
      expect(log.target).to eq(report)
      expect(log.metadata["new_status"]).to eq("reviewed")
    end
  end
end
