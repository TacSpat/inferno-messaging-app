require 'rails_helper'

RSpec.describe DataExportJob, type: :job do
  describe "#perform" do
    let(:export) { create(:data_export) }

    it "calls DataExportService" do
      expect(DataExportService).to receive(:call).with(export)
      described_class.perform_now(export.id)
    end

    it "completes the export successfully" do
      described_class.perform_now(export.id)
      expect(export.reload.status).to eq("completed")
    end

    it "marks export as failed on error" do
      allow(DataExportService).to receive(:call).and_raise(StandardError, "boom")

      expect {
        described_class.perform_now(export.id)
      }.to raise_error(StandardError)

      expect(export.reload.status).to eq("failed")
    end
  end

  after do
    # Cleanup any generated files
    DataExport.where(status: "completed").find_each do |e|
      File.delete(e.file_path) if e.file_path && File.exist?(e.file_path)
    end
  end
end
