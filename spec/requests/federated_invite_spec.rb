require "rails_helper"

RSpec.describe "Federated Invite Flow", type: :request do
  let(:server) { create(:server) }
  let!(:channel) { create(:channel, server: server) }
  let(:invite) { create(:invite, server: server) }

  describe "POST /invite/:code/accept with home_instance" do
    context "when not logged in and home_instance is present" do
      it "stores pending_invite_code in session and redirects to nostr auth" do
        post accept_invite_path(invite.code), params: { home_instance: "home.example.com" }

        expect(response).to redirect_to(nostr_auth_path(home_instance: "home.example.com"))
        expect(session[:pending_invite_code]).to eq(invite.code)
      end
    end

    context "when not logged in and home_instance is absent" do
      it "redirects to registration (existing behavior)" do
        post accept_invite_path(invite.code)

        expect(response).to redirect_to(new_user_registration_path)
        expect(session[:pending_invite_code]).to eq(invite.code)
      end
    end
  end

  describe "GET /invite/:code with ?from= param" do
    context "when not logged in and from param is present" do
      it "auto-redirects to nostr auth and stores invite code in session" do
        get invite_path(invite.code, from: "home.example.com")

        expect(response).to redirect_to(nostr_auth_path(home_instance: "home.example.com"))
        expect(session[:pending_invite_code]).to eq(invite.code)
      end
    end

    context "when not logged in and from param is absent" do
      it "renders the invite page normally" do
        get invite_path(invite.code)

        expect(response).to have_http_status(:ok)
      end
    end

    context "when logged in" do
      let(:user) { create(:user, :confirmed) }

      before { sign_in user }

      it "ignores from param and renders normally" do
        get invite_path(invite.code, from: "home.example.com")

        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "GET /invite/:code with Referer header" do
    context "when not logged in and referer is from another instance" do
      it "renders the page with detected home instance" do
        get invite_path(invite.code), headers: { "Referer" => "https://other.instance.com/some/page" }

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("other.instance.com")
        expect(response.body).to include("Continue from other.instance.com")
      end
    end

    context "when not logged in and referer is from same instance" do
      it "does not detect a home instance" do
        # www.example.com is the default test host
        get invite_path(invite.code), headers: { "Referer" => "http://www.example.com/channels" }

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("Continue from")
      end
    end

    context "when not logged in and no referer" do
      it "shows manual form without pre-fill" do
        get invite_path(invite.code)

        expect(response).to have_http_status(:ok)
        expect(response.body).to include("Have an account on another instance?")
        expect(response.body).not_to include("Continue from")
      end
    end
  end
end
