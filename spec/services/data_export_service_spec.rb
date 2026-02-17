require 'rails_helper'

RSpec.describe DataExportService do
  describe ".call" do
    let(:export) { create(:data_export) }

    it "transitions export to processing then completed" do
      described_class.call(export)
      export.reload

      expect(export.status).to eq("completed")
      expect(export.file_path).to be_present
      expect(export.expires_at).to be_present
    end

    it "creates a file at the export path" do
      described_class.call(export)
      expect(File.exist?(export.reload.file_path)).to be true
    end

    after do
      # Cleanup generated file
      path = export.reload.file_path
      File.delete(path) if path && File.exist?(path)
    end
  end
end
