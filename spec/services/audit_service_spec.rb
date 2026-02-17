require 'rails_helper'

RSpec.describe AuditService do
  describe ".log" do
    it "creates a FederationAuditLog record" do
      expect {
        described_class.log(
          event_type: "auth_attempt",
          remote_domain: "remote.chat",
          ip_address: "1.2.3.4",
          metadata: { nonce: "abc123" }
        )
      }.to change(FederationAuditLog, :count).by(1)
    end

    it "stores all provided attributes" do
      user = create(:user, :confirmed)
      server = create(:server)

      described_class.log(
        event_type: "domain_block",
        actor: user,
        target: server,
        remote_domain: "blocked.chat",
        ip_address: "10.0.0.1",
        metadata: { reason: "spam" }
      )

      log = FederationAuditLog.last
      expect(log.event_type).to eq("domain_block")
      expect(log.actor).to eq(user)
      expect(log.target).to eq(server)
      expect(log.remote_domain).to eq("blocked.chat")
      expect(log.ip_address.to_s).to eq("10.0.0.1")
      expect(log.metadata).to eq("reason" => "spam")
    end

    it "works with minimal arguments" do
      expect {
        described_class.log(event_type: "lockdown_activated")
      }.to change(FederationAuditLog, :count).by(1)
    end

    context "when creation fails" do
      it "raises in development/test" do
        expect {
          described_class.log(event_type: "invalid_event")
        }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end
end
