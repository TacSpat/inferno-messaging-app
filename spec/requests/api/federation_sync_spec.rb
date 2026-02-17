require 'rails_helper'

RSpec.describe "Api::FederationSync", type: :request do
  let(:remote_user_detail) do
    create(:remote_user,
      username: "alice",
      home_instance: "home.chat",
      federation_token: "sync-token"
    )
  end
  let(:shadow_user) do
    user = User.new(
      username: "alice",
      display_name: "alice",
      email: "nostr+apisync@home.chat",
      password: "password123",
      remote: true,
      remote_user_detail: remote_user_detail,
      public_id: SecureRandom.alphanumeric(12)
    )
    user.skip_confirmation!
    user.save!(validate: false)
    user
  end

  let(:profile_response) do
    { username: "alice", display_name: "Alice Synced", profile_color: "#123456" }.to_json
  end

  before do
    sign_in shadow_user
    pubkey = remote_user_detail.nostr_public_key
    base = "https://home.chat/federation/profiles/#{pubkey}"
    headers = { "Content-Type" => "application/json" }

    stub_request(:get, /#{Regexp.escape(base)}(\?|$)/).to_return(status: 200, body: profile_response, headers: headers)
    stub_request(:get, /#{Regexp.escape(base)}\/servers/).to_return(status: 200, body: { servers: [] }.to_json, headers: headers)
    stub_request(:get, /#{Regexp.escape(base)}\/conversations/).to_return(status: 200, body: { conversations: [] }.to_json, headers: headers)
    stub_request(:get, /#{Regexp.escape(base)}\/friends/).to_return(status: 200, body: { friends: [] }.to_json, headers: headers)
    stub_request(:get, /#{Regexp.escape(base)}\/folders/).to_return(status: 200, body: { folders: [] }.to_json, headers: headers)
    stub_request(:get, /#{Regexp.escape(base)}\/gif_collections/).to_return(status: 200, body: { gif_collections: [] }.to_json, headers: headers)
  end

  describe "POST /api/federation_sync" do
    it "syncs data and returns synced items" do
      post api_federation_sync_path, as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("ok")
      expect(body["synced"]).to include("profile")
    end

    it "updates remote user profile data" do
      post api_federation_sync_path, as: :json

      remote_user_detail.reload
      expect(remote_user_detail.display_name).to eq("Alice Synced")
      expect(remote_user_detail.profile_color).to eq("#123456")
    end

    it "passes federation token in requests" do
      post api_federation_sync_path, as: :json

      expect(WebMock).to have_requested(:get, /federation\/profiles/)
        .with(headers: { "X-Federation-Token" => "sync-token" })
        .at_least_once
    end

    it "returns skipped for local users" do
      local_user = create(:user, :confirmed)
      sign_in local_user

      post api_federation_sync_path, as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("skipped")
    end

    it "requires authentication" do
      sign_out shadow_user
      post api_federation_sync_path, as: :json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
