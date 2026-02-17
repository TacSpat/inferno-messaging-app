require 'rails_helper'

RSpec.describe Suspendable, type: :model do
  describe "#suspended?" do
    it "returns true when suspended_at is set" do
      user = build(:user, suspended_at: Time.current)
      expect(user.suspended?).to be true
    end

    it "returns false when suspended_at is nil" do
      user = build(:user, suspended_at: nil)
      expect(user.suspended?).to be false
    end
  end

  describe "#active_for_authentication?" do
    it "returns false when user is suspended" do
      user = create(:user, :confirmed, suspended_at: Time.current)
      expect(user.active_for_authentication?).to be false
    end

    it "returns true when user is not suspended" do
      user = create(:user, :confirmed)
      expect(user.active_for_authentication?).to be true
    end
  end

  describe "#inactive_message" do
    it "returns :suspended when user is suspended" do
      user = build(:user, :confirmed, suspended_at: Time.current)
      expect(user.inactive_message).to eq(:suspended)
    end

    it "returns default message when not suspended" do
      user = create(:user, :confirmed)
      expect(user.inactive_message).not_to eq(:suspended)
    end
  end

  describe "scopes" do
    let!(:active_user) { create(:user, :confirmed) }
    let!(:suspended_user) { create(:user, :confirmed, suspended_at: Time.current) }

    describe ".active_users" do
      it "excludes suspended users" do
        expect(User.active_users).to include(active_user)
        expect(User.active_users).not_to include(suspended_user)
      end
    end

    describe ".suspended_users" do
      it "returns only suspended users" do
        expect(User.suspended_users).to include(suspended_user)
        expect(User.suspended_users).not_to include(active_user)
      end
    end
  end
end
