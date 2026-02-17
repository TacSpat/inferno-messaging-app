require 'rails_helper'

RSpec.describe UserSuspensionService do
  let(:admin) { create(:user, :confirmed, :admin) }
  let(:user) { create(:user, :confirmed) }

  describe ".suspend!" do
    it "creates a UserSuspension record" do
      expect {
        described_class.suspend!(user, suspended_by: admin, type: "permanent", reason: "TOS violation")
      }.to change(UserSuspension, :count).by(1)
    end

    it "sets suspended_at on the user" do
      described_class.suspend!(user, suspended_by: admin, type: "permanent", reason: "TOS violation")
      expect(user.reload.suspended_at).to be_present
    end

    it "logs an audit event" do
      expect {
        described_class.suspend!(user, suspended_by: admin, type: "permanent", reason: "TOS violation", reason_category: "harassment")
      }.to change(FederationAuditLog, :count).by(1)

      log = FederationAuditLog.last
      expect(log.event_type).to eq("user_suspended")
      expect(log.actor).to eq(admin)
      expect(log.target).to eq(user)
      expect(log.metadata).to include("reason_category" => "harassment", "suspension_type" => "permanent")
    end

    it "returns the suspension record" do
      result = described_class.suspend!(user, suspended_by: admin, type: "temporary", reason: "Spam", expires_at: 7.days.from_now)
      expect(result).to be_a(UserSuspension)
      expect(result.suspension_type).to eq("temporary")
      expect(result.expires_at).to be_present
    end
  end

  describe ".lift!" do
    let!(:suspension) do
      described_class.suspend!(user, suspended_by: admin, type: "permanent", reason: "TOS violation")
    end

    it "lifts the suspension" do
      described_class.lift!(suspension, lifted_by: admin, reason: "Appeal approved")
      expect(suspension.reload.lifted_at).to be_present
      expect(suspension.lift_reason).to eq("Appeal approved")
    end

    it "clears suspended_at on the user" do
      described_class.lift!(suspension, lifted_by: admin)
      expect(user.reload.suspended_at).to be_nil
    end

    it "logs an audit event" do
      expect {
        described_class.lift!(suspension, lifted_by: admin, reason: "Appeal approved")
      }.to change(FederationAuditLog, :count).by(1)

      log = FederationAuditLog.last
      expect(log.event_type).to eq("user_suspension_lifted")
      expect(log.actor).to eq(admin)
      expect(log.target).to eq(user)
    end
  end
end
