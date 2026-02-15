require 'rails_helper'

RSpec.describe "Nostr::Signing", type: :request do
  include NostrTestHelpers

  let(:user) do
    user = create(:user, :confirmed, nostr_public_key: test_public_key)
    allow(user).to receive(:nostr_private_key).and_return(test_private_key)
    user
  end

  let(:valid_params) do
    {
      challenge: SecureRandom.hex(32),
      callback: "https://remote.chat/auth/nostr/callback",
      requesting_domain: "remote.chat"
    }
  end

  describe "GET /auth/nostr/sign" do
    it "requires authentication" do
      get nostr_auth_sign_path, params: valid_params
      expect(response).to redirect_to(new_user_session_path)
    end

    it "shows the confirmation page when signed in" do
      sign_in user
      get nostr_auth_sign_path, params: valid_params
      expect(response).to have_http_status(:ok)
    end

    it "redirects when params are missing" do
      sign_in user
      get nostr_auth_sign_path, params: { challenge: "abc" }
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST /auth/nostr/sign" do
    it "requires authentication" do
      post nostr_auth_sign_path, params: valid_params
      expect(response).to redirect_to(new_user_session_path)
    end

    it "signs the challenge and redirects to callback" do
      sign_in user
      # Need to stub the private key access through the controller
      allow_any_instance_of(Nostr::SigningController).to receive(:current_user).and_return(user)

      post nostr_auth_sign_path, params: valid_params

      expect(response).to have_http_status(:redirect)
      expect(response.location).to start_with(valid_params[:callback])
      expect(response.location).to include("event=")
    end
  end
end
