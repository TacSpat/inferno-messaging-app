require 'rails_helper'

RSpec.describe "Admin::UserSuspensions", type: :request do
  let(:admin) { create(:user, :confirmed, :admin) }
  let(:user) { create(:user, :confirmed) }

  before { sign_in admin }

  describe "GET /admin/user_suspensions" do
    it "shows the suspensions page" do
      get admin_user_suspensions_path
      expect(response).to have_http_status(:ok)
    end

    it "lists active suspensions" do
      UserSuspensionService.suspend!(user, suspended_by: admin, type: "permanent", reason: "Test")
      get admin_user_suspensions_path
      expect(response.body).to include(user.username)
    end
  end

  describe "POST /admin/user_suspensions" do
    it "suspends a user" do
      post admin_user_suspensions_path, params: {
        user_id: user.id,
        suspension_type: "permanent",
        reason: "Spam",
        reason_category: "spam"
      }

      expect(response).to redirect_to(admin_user_suspensions_path)
      expect(user.reload.suspended?).to be true
    end

    it "creates a temporary suspension with expiry" do
      post admin_user_suspensions_path, params: {
        user_id: user.id,
        suspension_type: "temporary",
        reason: "Cooling off",
        expires_at: 7.days.from_now.iso8601
      }

      expect(user.reload.suspended?).to be true
      expect(UserSuspension.last.expires_at).to be_present
    end

    it "rejects suspension of nonexistent user" do
      post admin_user_suspensions_path, params: {
        user_id: 0,
        suspension_type: "permanent",
        reason: "Test"
      }

      expect(response).to redirect_to(admin_user_suspensions_path)
      expect(flash[:alert]).to include("not found")
    end

    it "rejects suspension of already-suspended user" do
      UserSuspensionService.suspend!(user, suspended_by: admin, type: "permanent", reason: "First")

      post admin_user_suspensions_path, params: {
        user_id: user.id,
        suspension_type: "permanent",
        reason: "Second"
      }

      expect(response).to redirect_to(admin_user_suspensions_path)
      expect(flash[:alert]).to include("already suspended")
    end
  end

  describe "DELETE /admin/user_suspensions/:id" do
    it "lifts a suspension" do
      suspension = UserSuspensionService.suspend!(user, suspended_by: admin, type: "permanent", reason: "Test")

      delete admin_user_suspension_path(suspension), params: { lift_reason: "Appeal approved" }

      expect(response).to redirect_to(admin_user_suspensions_path)
      expect(user.reload.suspended?).to be false
      expect(suspension.reload.lift_reason).to eq("Appeal approved")
    end
  end

  context "when not an admin" do
    let(:regular_user) { create(:user, :confirmed) }

    before { sign_in regular_user }

    it "denies access to index" do
      get admin_user_suspensions_path
      expect(response).to redirect_to(root_path)
    end
  end
end
