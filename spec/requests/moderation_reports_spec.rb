require 'rails_helper'

RSpec.describe "ModerationReports", type: :request do
  describe "POST /moderation_reports" do
    let(:user) { sign_in_as_user }

    before { user }

    it "creates a report" do
      expect {
        post moderation_reports_path, params: {
          reported_pubkey: SecureRandom.hex(32),
          report_type: "spam",
          reason: "Spamming the chat"
        }
      }.to change(ModerationReport, :count).by(1)
    end

    it "rejects missing reported_pubkey" do
      post moderation_reports_path, params: {
        report_type: "spam"
      }
      expect(flash[:alert]).to include("Missing reported user")
    end

    it "rejects invalid report_type" do
      post moderation_reports_path, params: {
        reported_pubkey: SecureRandom.hex(32),
        report_type: "invalid_type"
      }
      expect(flash[:alert]).to be_present
    end

    it "requires authentication" do
      sign_out user
      post moderation_reports_path, params: {
        reported_pubkey: SecureRandom.hex(32),
        report_type: "spam"
      }
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
