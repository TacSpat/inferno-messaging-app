require 'rails_helper'

RSpec.describe LiftExpiredSuspensionsJob, type: :job do
  let(:admin) { create(:user, :confirmed, :admin) }

  it "lifts expired temporary suspensions" do
    user = create(:user, :confirmed)
    suspension = UserSuspensionService.suspend!(
      user,
      suspended_by: admin,
      type: "temporary",
      reason: "Cooling off",
      expires_at: 1.hour.ago
    )

    described_class.new.perform

    expect(suspension.reload.lifted_at).to be_present
    expect(suspension.lift_reason).to eq("Automatic expiry")
    expect(user.reload.suspended_at).to be_nil
  end

  it "does not lift non-expired suspensions" do
    user = create(:user, :confirmed)
    suspension = UserSuspensionService.suspend!(
      user,
      suspended_by: admin,
      type: "temporary",
      reason: "Cooling off",
      expires_at: 7.days.from_now
    )

    described_class.new.perform

    expect(suspension.reload.lifted_at).to be_nil
    expect(user.reload.suspended_at).to be_present
  end

  it "does not lift permanent suspensions" do
    user = create(:user, :confirmed)
    suspension = UserSuspensionService.suspend!(
      user,
      suspended_by: admin,
      type: "permanent",
      reason: "Banned"
    )

    described_class.new.perform

    expect(suspension.reload.lifted_at).to be_nil
    expect(user.reload.suspended_at).to be_present
  end
end
