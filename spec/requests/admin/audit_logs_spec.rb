require 'rails_helper'

RSpec.describe "Admin::AuditLogs", type: :request do
  describe "GET /admin/audit_logs" do
    it "requires admin access" do
      sign_in_as_user
      get admin_audit_logs_path
      expect(response).to redirect_to(root_path)
    end

    it "shows audit log page for admin" do
      sign_in_as_admin
      get admin_audit_logs_path
      expect(response).to have_http_status(:ok)
    end

    it "displays federation audit logs" do
      sign_in_as_admin
      create(:federation_audit_log, event_type: "auth_attempt", remote_domain: "test.chat")

      get admin_audit_logs_path
      expect(response.body).to include("Auth attempt")
      expect(response.body).to include("test.chat")
    end

    it "displays PaperTrail model versions" do
      sign_in_as_admin
      config = InstanceConfig.current
      config.update!(federation_mode: "closed")

      get admin_audit_logs_path
      expect(response.body).to include("InstanceConfig")
    end

    context "with filters" do
      before { sign_in_as_admin }

      it "filters by event type" do
        create(:federation_audit_log, event_type: "auth_attempt")
        create(:federation_audit_log, :domain_block)

        get admin_audit_logs_path, params: { event_type: "auth_attempt" }
        expect(response).to have_http_status(:ok)
      end

      it "filters by domain" do
        create(:federation_audit_log, remote_domain: "target.chat")
        create(:federation_audit_log, remote_domain: "other.chat")

        get admin_audit_logs_path, params: { domain: "target.chat" }
        expect(response).to have_http_status(:ok)
      end

      it "filters by date range" do
        create(:federation_audit_log)

        get admin_audit_logs_path, params: {
          date_from: Date.yesterday.to_s,
          date_to: Date.tomorrow.to_s
        }
        expect(response).to have_http_status(:ok)
      end
    end
  end
end
