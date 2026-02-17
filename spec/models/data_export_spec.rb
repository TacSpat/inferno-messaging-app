require 'rails_helper'

RSpec.describe DataExport, type: :model do
  describe "validations" do
    it { should validate_presence_of(:status) }
    it { should validate_inclusion_of(:status).in_array(DataExport::STATUSES) }
    it { should validate_presence_of(:export_type) }
    it { should validate_inclusion_of(:export_type).in_array(DataExport::EXPORT_TYPES) }
  end

  describe "associations" do
    it { should belong_to(:user) }
    it { should belong_to(:requested_by).class_name("User") }
  end

  describe "status transitions" do
    let(:export) { create(:data_export) }

    describe "#process!" do
      it "transitions to processing" do
        export.process!
        expect(export.status).to eq("processing")
      end
    end

    describe "#complete!" do
      it "transitions to completed with file path and expiry" do
        export.complete!("/tmp/export.zip")

        expect(export.status).to eq("completed")
        expect(export.file_path).to eq("/tmp/export.zip")
        expect(export.expires_at).to be_within(1.minute).of(7.days.from_now)
      end
    end

    describe "#fail!" do
      it "transitions to failed" do
        export.fail!
        expect(export.status).to eq("failed")
      end
    end
  end

  describe "#expired?" do
    it "returns true when expires_at is in the past" do
      export = create(:data_export, expires_at: 1.day.ago)
      expect(export.expired?).to be true
    end

    it "returns false when expires_at is in the future" do
      export = create(:data_export, expires_at: 1.day.from_now)
      expect(export.expired?).to be false
    end

    it "returns false when expires_at is nil" do
      export = create(:data_export, expires_at: nil)
      expect(export.expired?).to be false
    end
  end

  describe "PaperTrail tracking" do
    it "creates a version on creation" do
      expect { create(:data_export) }.to change(PaperTrail::Version, :count)
    end
  end
end
