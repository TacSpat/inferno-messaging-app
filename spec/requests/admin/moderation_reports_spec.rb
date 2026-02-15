require 'rails_helper'

RSpec.describe "Admin::ModerationReports", type: :request do
  describe "GET /admin/moderation_reports" do
    it "requires admin access" do
      sign_in_as_user
      get admin_moderation_reports_path
      expect(response).to redirect_to(root_path)
    end

    it "shows reports for admin" do
      sign_in_as_admin
      create(:moderation_report)
      get admin_moderation_reports_path
      expect(response).to have_http_status(:ok)
    end

    it "filters by resolved status" do
      sign_in_as_admin
      create(:moderation_report)
      create(:moderation_report, :reviewed)

      get admin_moderation_reports_path, params: { filter: "resolved" }
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /admin/moderation_reports/:id" do
    it "shows a specific report" do
      sign_in_as_admin
      report = create(:moderation_report)
      get admin_moderation_report_path(report)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /admin/moderation_reports/:id/review" do
    let(:admin) { sign_in_as_admin }
    let(:report) { create(:moderation_report) }

    before { admin }

    it "changes report status" do
      post review_admin_moderation_report_path(report), params: { status: "reviewed" }

      expect(response).to redirect_to(admin_moderation_reports_path)
      expect(report.reload.status).to eq("reviewed")
      expect(report.reviewed_by).to eq(admin)
    end

    it "rejects invalid status" do
      post review_admin_moderation_report_path(report), params: { status: "invalid" }
      expect(response).to redirect_to(admin_moderation_report_path(report))
    end

    it "publishes NIP-56 when requested for actioned reports" do
      expect(NostrReportPublishJob).to receive(:perform_later).with(report.id)

      post review_admin_moderation_report_path(report), params: {
        status: "actioned",
        publish_to_relays: "1"
      }
    end

    it "does not publish NIP-56 for non-actioned status" do
      expect(NostrReportPublishJob).not_to receive(:perform_later)

      post review_admin_moderation_report_path(report), params: {
        status: "reviewed",
        publish_to_relays: "1"
      }
    end
  end
end
