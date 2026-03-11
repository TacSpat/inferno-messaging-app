require 'rails_helper'

RSpec.describe Call, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:conversation) }
    it { is_expected.to belong_to(:initiated_by).class_name("User") }
    it { is_expected.to have_many(:call_participants).dependent(:destroy) }
  end

  describe "scope :active" do
    let(:conversation) { create(:conversation) }
    let(:user) { create(:user, :confirmed) }

    it "returns ringing and active calls" do
      ringing = conversation.calls.create!(initiated_by: user, status: "ringing")
      active = conversation.calls.create!(initiated_by: user, status: "active")
      ended = conversation.calls.create!(initiated_by: user, status: "ended")
      declined = conversation.calls.create!(initiated_by: user, status: "declined")

      result = Call.active
      expect(result).to include(ringing, active)
      expect(result).not_to include(ended, declined)
    end
  end

  describe "#room_name" do
    it "returns formatted room name" do
      conversation = create(:conversation)
      call = conversation.calls.create!(initiated_by: create(:user, :confirmed), status: "ringing")

      expect(call.room_name).to eq("dm-#{conversation.public_id}-#{call.public_id}")
    end
  end

  describe "#duration" do
    let(:call) { build(:call) }

    it "returns seconds when both timestamps set" do
      call.started_at = 5.minutes.ago
      call.ended_at = Time.current
      expect(call.duration).to be_within(1).of(300)
    end

    it "returns nil when timestamps missing" do
      expect(call.duration).to be_nil
    end
  end

  describe "#joinable?" do
    it "is true for ringing" do
      expect(build(:call, status: "ringing").joinable?).to be true
    end

    it "is true for active" do
      expect(build(:call, status: "active").joinable?).to be true
    end

    it "is false for ended" do
      expect(build(:call, status: "ended").joinable?).to be false
    end

    it "is false for declined" do
      expect(build(:call, status: "declined").joinable?).to be false
    end
  end
end
