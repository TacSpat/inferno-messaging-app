require 'rails_helper'

RSpec.describe DomainBlockSnapshotService do
  describe ".call" do
    let(:blocklist_entry) { create(:instance_blocklist, domain: "evil.chat") }

    it "creates a DomainBlockSnapshot" do
      # The after_create callback already creates one, so destroy it first
      blocklist_entry.domain_block_snapshot&.destroy

      expect {
        described_class.call(blocklist_entry)
      }.to change(DomainBlockSnapshot, :count).by(1)
    end

    it "captures remote user count" do
      blocklist_entry.domain_block_snapshot&.destroy
      snapshot = described_class.call(blocklist_entry)

      expect(snapshot.snapshot_data["remote_user_count"]).to eq(0)
    end

    it "captures server membership count" do
      blocklist_entry.domain_block_snapshot&.destroy
      snapshot = described_class.call(blocklist_entry)

      expect(snapshot.snapshot_data["server_membership_count"]).to eq(0)
    end

    it "captures recent audit events for the domain" do
      FederationAuditLog.delete_all # clean up readonly records with raw SQL
      AuditService.log(event_type: "auth_attempt", remote_domain: "evil.chat")

      blocklist_entry.domain_block_snapshot&.destroy
      snapshot = described_class.call(blocklist_entry)

      expect(snapshot.snapshot_data["recent_audit_events"].length).to eq(1)
      expect(snapshot.snapshot_data["recent_audit_events"].first["event_type"]).to eq("auth_attempt")
    end
  end
end
