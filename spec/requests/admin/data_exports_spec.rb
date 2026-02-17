require 'rails_helper'

RSpec.describe "Admin::DataExports", type: :request do
  describe "GET /admin/data_exports" do
    it "requires admin access" do
      sign_in_as_user
      get admin_data_exports_path
      expect(response).to redirect_to(root_path)
    end

    it "shows data exports page for admin" do
      sign_in_as_admin
      get admin_data_exports_path
      expect(response).to have_http_status(:ok)
    end

    it "displays existing exports" do
      sign_in_as_admin
      export = create(:data_export)
      get admin_data_exports_path
      expect(response.body).to include("Pending")
    end
  end

  describe "POST /admin/data_exports" do
    let(:admin) { sign_in_as_admin }
    let(:target_user) { create(:user, :confirmed) }

    before { admin }

    it "creates a data export and enqueues job" do
      expect(DataExportJob).to receive(:perform_later).with(anything)

      expect {
        post admin_data_exports_path, params: {
          user_id: target_user.id,
          export_type: "full"
        }
      }.to change(DataExport, :count).by(1)

      expect(response).to redirect_to(admin_data_exports_path)
      export = DataExport.last
      expect(export.user).to eq(target_user)
      expect(export.requested_by).to eq(admin)
      expect(export.export_type).to eq("full")
    end

    it "defaults export_type to full" do
      post admin_data_exports_path, params: { user_id: target_user.id }

      expect(DataExport.last.export_type).to eq("full")
    end
  end

  describe "GET /admin/data_exports/:id/download" do
    let(:admin) { sign_in_as_admin }

    before { admin }

    it "returns error for incomplete exports" do
      export = create(:data_export, status: "pending")
      get download_admin_data_export_path(export)

      expect(response).to redirect_to(admin_data_exports_path)
      expect(flash[:alert]).to include("not ready")
    end

    it "returns error for expired exports" do
      export = create(:data_export, status: "completed", file_path: "/tmp/test.zip", expires_at: 1.day.ago)
      get download_admin_data_export_path(export)

      expect(response).to redirect_to(admin_data_exports_path)
      expect(flash[:alert]).to include("expired")
    end
  end
end
