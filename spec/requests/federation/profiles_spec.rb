require 'rails_helper'

RSpec.describe "Federation::Profiles", type: :request do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { create(:user, :confirmed, username: "tacspat", bio: "Hello", profile_color: "#ff5500") }
  let(:pubkey) { user.nostr_public_key }
  let(:requesting_instance) { "remote.chat" }
  let(:token) { FederationTokenService.generate(pubkey: pubkey, requesting_instance: requesting_instance) }

  def get_with_token(path, token: self.token, requesting_instance: self.requesting_instance)
    get path, params: { requesting_instance: requesting_instance },
        headers: { "X-Federation-Token" => token }
  end

  describe "GET /federation/profiles/:pubkey" do
    it "returns profile data with valid token" do
      get_with_token federation_federation_profile_path(pubkey)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["pubkey"]).to eq(pubkey)
      expect(body["username"]).to eq("tacspat")
      expect(body["bio"]).to eq("Hello")
      expect(body["profile_color"]).to eq("#ff5500")
      expect(body["home_instance"]).to eq("localhost")
      expect(body["nip05"]).to eq("tacspat@localhost")
      expect(body["synced_at"]).to be_present
    end

    it "returns 404 for unknown pubkey" do
      get_with_token federation_federation_profile_path("0000000000000000"),
                     token: FederationTokenService.generate(pubkey: "0000000000000000", requesting_instance: requesting_instance)

      expect(response).to have_http_status(:not_found)
    end

    it "returns 401 without a token" do
      get federation_federation_profile_path(pubkey),
          params: { requesting_instance: requesting_instance }

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)["error"]).to include("token required")
    end

    it "returns 401 with an invalid token" do
      get federation_federation_profile_path(pubkey),
          params: { requesting_instance: requesting_instance },
          headers: { "X-Federation-Token" => "garbage" }

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 when token pubkey doesn't match" do
      other_token = FederationTokenService.generate(pubkey: SecureRandom.hex(32), requesting_instance: requesting_instance)
      get_with_token federation_federation_profile_path(pubkey), token: other_token

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to include("does not match")
    end

    it "returns 403 when token instance doesn't match requesting_instance param" do
      wrong_instance_token = FederationTokenService.generate(pubkey: pubkey, requesting_instance: "evil.chat")
      get_with_token federation_federation_profile_path(pubkey),
                     token: wrong_instance_token, requesting_instance: requesting_instance

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to include("mismatch")
    end

    it "returns 401 with an expired token" do
      old_token = token
      travel 31.days do
        get_with_token federation_federation_profile_path(pubkey), token: old_token
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "does not return remote users" do
      fake_pubkey = SecureRandom.hex(32)
      remote_detail = create(:remote_user, home_instance: "other.chat", nostr_public_key: fake_pubkey)
      remote_user = create(:user, :confirmed, remote: true, remote_user_detail: remote_detail, nostr_public_key: fake_pubkey)
      remote_token = FederationTokenService.generate(pubkey: fake_pubkey, requesting_instance: requesting_instance)

      get_with_token federation_federation_profile_path(fake_pubkey), token: remote_token
      expect(response).to have_http_status(:not_found)
    end

    context "when federation is closed" do
      before do
        InstanceConfig.current.update!(federation_mode: "closed")
      end

      it "returns 403" do
        get_with_token federation_federation_profile_path(pubkey)
        expect(response).to have_http_status(:forbidden)
      end
    end

    context "when requesting instance is blocked" do
      before do
        admin = create(:user, :confirmed, :admin)
        InstanceBlocklist.create!(domain: requesting_instance, blocked_by: admin, blocked_at: Time.current)
      end

      it "returns 403" do
        get_with_token federation_federation_profile_path(pubkey)
        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "GET /federation/profiles/:pubkey/servers" do
    it "returns the user's server list" do
      server = create(:server, owner: user, name: "My Server")

      get_with_token federation_federation_profile_servers_path(pubkey)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      servers = body["servers"]
      expect(servers.length).to eq(1)
      expect(servers[0]["name"]).to eq("My Server")
      expect(servers[0]["server_id"]).to eq(server.public_id)
      expect(servers[0]["invite_code"]).to be_present
      expect(servers[0]["emojis"]).to be_an(Array)
      expect(servers[0]["stickers"]).to be_an(Array)
    end

    it "returns 401 without token" do
      get federation_federation_profile_servers_path(pubkey),
          params: { requesting_instance: requesting_instance }
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /federation/profiles/:pubkey/conversations" do
    it "returns the user's conversations" do
      other_user = create(:user, :confirmed, username: "bob")
      Conversation.find_or_create_direct(user, other_user)

      get_with_token federation_federation_profile_conversations_path(pubkey)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      convs = body["conversations"]
      expect(convs.length).to eq(1)
      expect(convs[0]["kind"]).to eq("direct")
      expect(convs[0]["other_user"]["username"]).to eq("bob")
    end
  end

  describe "GET /federation/profiles/:pubkey/gif_collections" do
    it "returns the user's GIF collections with favorites" do
      collection = user.gif_collections.create!(name: "Reactions", position: 0)
      collection.gif_favorites.create!(
        user: user,
        tenor_gif_id: "abc123",
        tenor_url: "https://tenor.com/abc123",
        preview_url: "https://media.tenor.com/preview.gif",
        gif_url: "https://media.tenor.com/full.gif",
        description: "Funny",
        position: 0
      )

      get_with_token federation_federation_profile_gif_collections_path(pubkey)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      collections = body["gif_collections"]
      expect(collections.length).to eq(1)
      expect(collections[0]["name"]).to eq("Reactions")
      expect(collections[0]["favorites"].length).to eq(1)
      expect(collections[0]["favorites"][0]["tenor_gif_id"]).to eq("abc123")
    end
  end
end
