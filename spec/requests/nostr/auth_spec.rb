require 'rails_helper'

RSpec.describe "Nostr::Auth", type: :request do
  describe "GET /auth/nostr" do
    it "redirects to home instance signing endpoint" do
      get nostr_auth_path, params: { home_instance: "home.chat" }

      expect(response).to have_http_status(:redirect)
      expect(response.location).to include("home.chat/auth/nostr/sign")
    end

    it "creates a NostrAuthChallenge" do
      expect {
        get nostr_auth_path, params: { home_instance: "home.chat" }
      }.to change(NostrAuthChallenge, :count).by(1)
    end

    it "requires home_instance parameter" do
      get nostr_auth_path
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include("Home instance is required")
    end

    context "federation checks" do
      it "blocks when federation is closed" do
        InstanceConfig.current.update!(federation_mode: "closed")

        get nostr_auth_path, params: { home_instance: "home.chat" }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("does not accept remote authentication")
      end

      it "blocks when remote auth is locked down" do
        InstanceConfig.current.update!(lockdown_remote_auth: true)

        get nostr_auth_path, params: { home_instance: "home.chat" }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("currently disabled")
      end

      it "blocks when full lockdown is active" do
        InstanceConfig.current.emergency_lockdown!

        get nostr_auth_path, params: { home_instance: "home.chat" }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("currently disabled")
      end
    end

    context "blocklist checks" do
      it "blocks domains on the blocklist" do
        admin = create(:user, :confirmed, :admin)
        InstanceBlocklist.create!(domain: "evil.chat", blocked_by: admin, blocked_at: Time.current)

        get nostr_auth_path, params: { home_instance: "evil.chat" }
        expect(response).to redirect_to(root_path)
        expect(flash[:alert]).to include("not allowed")
      end
    end
  end

  describe "GET /auth/nostr/callback" do
    include NostrTestHelpers

    let(:private_key) { test_private_key }
    let(:public_key) { test_public_key }

    it "requires event parameter" do
      get nostr_auth_callback_path
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include("Missing authentication event")
    end

    it "rejects invalid base64" do
      get nostr_auth_callback_path, params: { event: "not-valid-base64!!!" }
      expect(response).to redirect_to(root_path)
    end

    it "verifies signed event and creates session" do
      challenge = create(:nostr_auth_challenge)

      # Build a real signed event
      user = create(:user, :confirmed, nostr_public_key: public_key)
      allow(user).to receive(:nostr_private_key).and_return(private_key)

      signed_event = NostrEventService.build_auth_event(
        user: user,
        challenge: challenge.nonce,
        relay_url: challenge.callback_url
      )

      encoded = Base64.urlsafe_encode64(JSON.generate(signed_event))

      get nostr_auth_callback_path, params: { event: encoded }

      expect(response).to redirect_to(federation_syncing_path)
      expect(flash[:notice]).to be_present

      # Challenge should be consumed
      expect(challenge.reload.used).to be true
    end

    it "rejects expired challenges" do
      challenge = create(:nostr_auth_challenge, expires_at: 1.minute.ago)

      user = create(:user, :confirmed, nostr_public_key: public_key)
      allow(user).to receive(:nostr_private_key).and_return(private_key)

      signed_event = NostrEventService.build_auth_event(
        user: user,
        challenge: challenge.nonce,
        relay_url: challenge.callback_url
      )
      encoded = Base64.urlsafe_encode64(JSON.generate(signed_event))

      get nostr_auth_callback_path, params: { event: encoded }
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to include("Invalid or expired")
    end
  end
end
