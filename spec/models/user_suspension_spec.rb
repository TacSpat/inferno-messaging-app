require 'rails_helper'

RSpec.describe UserSuspension, type: :model do
  describe "validations" do
    it { should validate_presence_of(:suspension_type) }
    it { should validate_inclusion_of(:suspension_type).in_array(described_class::SUSPENSION_TYPES) }
    it { should validate_inclusion_of(:reason_category).in_array(described_class::REASON_CATEGORIES).allow_nil }
  end

  describe "associations" do
    it { should belong_to(:user) }
    it { should belong_to(:suspended_by).class_name("User").optional }
    it { should belong_to(:lifted_by).class_name("User").optional }
  end

  describe "scopes" do
    let!(:active_suspension) { create(:user_suspension) }
    let!(:lifted_suspension) { create(:user_suspension, :lifted) }

    describe ".active" do
      it "returns only active suspensions" do
        expect(described_class.active).to include(active_suspension)
        expect(described_class.active).not_to include(lifted_suspension)
      end
    end

    describe ".lifted" do
      it "returns only lifted suspensions" do
        expect(described_class.lifted).to include(lifted_suspension)
        expect(described_class.lifted).not_to include(active_suspension)
      end
    end

    describe ".expired" do
      let!(:expired_suspension) { create(:user_suspension, :expired) }

      it "returns active suspensions past their expiry" do
        expect(described_class.expired).to include(expired_suspension)
        expect(described_class.expired).not_to include(active_suspension)
      end
    end
  end

  describe "#active?" do
    it "returns true when lifted_at is nil" do
      suspension = build(:user_suspension, lifted_at: nil)
      expect(suspension.active?).to be true
    end

    it "returns false when lifted_at is set" do
      suspension = build(:user_suspension, :lifted)
      expect(suspension.active?).to be false
    end
  end

  describe "#permanent?" do
    it "returns true for permanent suspensions" do
      suspension = build(:user_suspension, suspension_type: "permanent")
      expect(suspension.permanent?).to be true
    end

    it "returns false for temporary suspensions" do
      suspension = build(:user_suspension, :temporary)
      expect(suspension.permanent?).to be false
    end
  end

  describe "#expired?" do
    it "returns true for temporary suspensions past expiry" do
      suspension = build(:user_suspension, :expired)
      expect(suspension.expired?).to be true
    end

    it "returns false for permanent suspensions" do
      suspension = build(:user_suspension, suspension_type: "permanent")
      expect(suspension.expired?).to be false
    end

    it "returns false for temporary suspensions not yet expired" do
      suspension = build(:user_suspension, :temporary)
      expect(suspension.expired?).to be false
    end
  end

  describe "#lift!" do
    it "sets lifted_at and lifted_by" do
      suspension = create(:user_suspension)
      admin = create(:user, :confirmed, :admin)

      suspension.lift!(admin, reason: "Appeal approved")

      expect(suspension.lifted_at).to be_present
      expect(suspension.lifted_by).to eq(admin)
      expect(suspension.lift_reason).to eq("Appeal approved")
    end

    it "clears suspended_at on user when no other active suspensions" do
      user = create(:user, :confirmed, suspended_at: Time.current)
      suspension = create(:user_suspension, user: user)
      admin = create(:user, :confirmed, :admin)

      suspension.lift!(admin)

      expect(user.reload.suspended_at).to be_nil
    end

    it "does not clear suspended_at when other active suspensions exist" do
      user = create(:user, :confirmed, suspended_at: Time.current)
      suspension1 = create(:user_suspension, user: user)
      create(:user_suspension, user: user, reason_category: "spam")
      admin = create(:user, :confirmed, :admin)

      suspension1.lift!(admin)

      expect(user.reload.suspended_at).to be_present
    end
  end

  describe "PaperTrail tracking" do
    it "creates a version on creation" do
      expect { create(:user_suspension) }.to change(PaperTrail::Version, :count)
    end
  end
end
