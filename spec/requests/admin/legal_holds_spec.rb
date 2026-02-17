require 'rails_helper'

RSpec.describe "Admin::LegalHolds", type: :request do
  describe "GET /admin/legal_holds" do
    it "requires admin access" do
      sign_in_as_user
      get admin_legal_holds_path
      expect(response).to redirect_to(root_path)
    end

    it "shows legal holds page for admin" do
      sign_in_as_admin
      get admin_legal_holds_path
      expect(response).to have_http_status(:ok)
    end

    it "displays active holds" do
      sign_in_as_admin
      user = create(:user, :confirmed)
      create(:legal_hold, holdable: user)

      get admin_legal_holds_path
      expect(response.body).to include("Active")
      expect(response.body).to include("User")
    end

    it "displays recently lifted holds" do
      sign_in_as_admin
      hold = create(:legal_hold, holdable: create(:user, :confirmed))
      hold.lift!

      get admin_legal_holds_path
      expect(response.body).to include("Lifted")
    end
  end

  describe "POST /admin/legal_holds" do
    let(:admin) { sign_in_as_admin }
    let(:target_user) { create(:user, :confirmed) }

    before { admin }

    it "places a legal hold on a user" do
      expect {
        post admin_legal_holds_path, params: {
          holdable_type: "User",
          holdable_id: target_user.id,
          reason: "Legal request #123"
        }
      }.to change(LegalHold, :count).by(1)

      expect(response).to redirect_to(admin_legal_holds_path)
      hold = LegalHold.last
      expect(hold.holdable).to eq(target_user)
      expect(hold.reason).to eq("Legal request #123")
      expect(hold.active).to be true
    end

    it "places a legal hold on a server" do
      server = create(:server)
      post admin_legal_holds_path, params: {
        holdable_type: "Server",
        holdable_id: server.id
      }

      expect(response).to redirect_to(admin_legal_holds_path)
      expect(LegalHold.last.holdable).to eq(server)
    end

    it "rejects hold on nonexistent record" do
      post admin_legal_holds_path, params: {
        holdable_type: "User",
        holdable_id: 999999
      }

      expect(response).to redirect_to(admin_legal_holds_path)
      expect(flash[:alert]).to include("not found")
    end

    it "rejects duplicate active hold" do
      create(:legal_hold, holdable: target_user)

      post admin_legal_holds_path, params: {
        holdable_type: "User",
        holdable_id: target_user.id
      }

      expect(response).to redirect_to(admin_legal_holds_path)
      expect(flash[:alert]).to include("already exists")
    end

    it "creates a federation audit log entry" do
      expect {
        post admin_legal_holds_path, params: {
          holdable_type: "User",
          holdable_id: target_user.id
        }
      }.to change(FederationAuditLog, :count).by(1)
    end
  end

  describe "DELETE /admin/legal_holds/:id" do
    it "lifts the hold" do
      admin = sign_in_as_admin
      hold = create(:legal_hold, holdable: create(:user, :confirmed))

      delete admin_legal_hold_path(hold)

      expect(response).to redirect_to(admin_legal_holds_path)
      expect(hold.reload.active).to be false
      expect(hold.lifted_at).to be_present
    end
  end
end
