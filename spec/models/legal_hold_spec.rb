require 'rails_helper'

RSpec.describe LegalHold, type: :model do
  describe "validations" do
    it { should validate_presence_of(:placed_at) }
  end

  describe "associations" do
    it { should belong_to(:holdable) }
    it { should belong_to(:placed_by).class_name("User") }
  end

  describe "scopes" do
    let!(:active_hold) { create(:legal_hold) }
    let!(:lifted_hold) { create(:legal_hold, :lifted, holdable: create(:user, :confirmed)) }

    describe ".active" do
      it "returns only active holds" do
        expect(described_class.active).to include(active_hold)
        expect(described_class.active).not_to include(lifted_hold)
      end
    end

    describe ".lifted" do
      it "returns only lifted holds" do
        expect(described_class.lifted).to include(lifted_hold)
        expect(described_class.lifted).not_to include(active_hold)
      end
    end
  end

  describe "#lift!" do
    it "sets active to false and records lifted_at" do
      hold = create(:legal_hold)
      hold.lift!

      expect(hold.active).to be false
      expect(hold.lifted_at).to be_present
    end
  end

  describe ".held?" do
    it "returns true for records with active holds" do
      hold = create(:legal_hold)
      expect(described_class.held?(hold.holdable)).to be true
    end

    it "returns false for records without holds" do
      user = create(:user, :confirmed)
      expect(described_class.held?(user)).to be false
    end

    it "returns false after hold is lifted" do
      hold = create(:legal_hold)
      holdable = hold.holdable
      hold.lift!

      expect(described_class.held?(holdable)).to be false
    end
  end

  describe "unique active hold constraint" do
    it "prevents duplicate active holds on the same record" do
      hold = create(:legal_hold)
      duplicate = build(:legal_hold, holdable: hold.holdable)

      expect { duplicate.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "allows a new active hold after the previous one is lifted" do
      hold = create(:legal_hold)
      holdable = hold.holdable
      hold.lift!

      new_hold = build(:legal_hold, holdable: holdable)
      expect { new_hold.save! }.not_to raise_error
    end
  end

  describe "PaperTrail tracking" do
    it "creates a version on creation" do
      expect { create(:legal_hold) }.to change(PaperTrail::Version, :count)
    end

    it "creates a version when lifted" do
      hold = create(:legal_hold)
      expect { hold.lift! }.to change(PaperTrail::Version, :count)
    end
  end

  describe "polymorphic holdable" do
    it "supports User holdable" do
      hold = create(:legal_hold, holdable: create(:user, :confirmed))
      expect(hold.holdable_type).to eq("User")
    end

    it "supports Server holdable" do
      hold = create(:legal_hold, :on_server)
      expect(hold.holdable_type).to eq("Server")
    end

    it "supports Channel holdable" do
      hold = create(:legal_hold, :on_channel)
      expect(hold.holdable_type).to eq("Channel")
    end
  end
end
