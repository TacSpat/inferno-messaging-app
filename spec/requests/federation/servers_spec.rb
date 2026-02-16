require 'rails_helper'

RSpec.describe "Federation::Servers", type: :request do
  include NostrTestHelpers

  let(:private_key) { test_private_key }
  let(:public_key) { test_public_key }

  def build_create_server_event(name:, description: nil, pubkey: public_key, privkey: private_key, home_relay: "wss://home.chat")
    content = { name: name, description: description, username: "testuser" }.to_json
    tags = [
      ["d", "create_server"],
      ["relay", home_relay]
    ]
    created_at = Time.now.to_i

    serialized = [0, pubkey, created_at, 30078, tags, content]
    id = Digest::SHA256.hexdigest(JSON.generate(serialized))

    message_bin = [id].pack("H*")
    private_key_bin = [privkey].pack("H*")
    signature = Schnorr.sign(message_bin, private_key_bin)
    sig_hex = signature.encode.unpack1("H*")

    {
      id: id,
      pubkey: pubkey,
      created_at: created_at,
      kind: 30078,
      tags: tags,
      content: content,
      sig: sig_hex
    }
  end

  describe "POST /federation/create_server" do
    it "creates a server with a valid signed event" do
      event = build_create_server_event(name: "Federation Test Server")

      expect {
        post federation_create_server_path, params: { event: event }, as: :json
      }.to change(Server, :count).by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["server_name"]).to eq("Federation Test Server")
      expect(body["server_id"]).to be_present
      expect(body["invite_code"]).to be_present
      expect(body["instance_domain"]).to eq(Rails.application.config.x.instance_domain)
    end

    it "creates a shadow user for the requester's pubkey" do
      event = build_create_server_event(name: "Remote Server")

      expect {
        post federation_create_server_path, params: { event: event }, as: :json
      }.to change(RemoteUser, :count).by(1)

      remote_user = RemoteUser.last
      expect(remote_user.nostr_public_key).to eq(public_key)
      expect(remote_user.home_instance).to eq("home.chat")
    end

    it "sets the shadow user as server owner" do
      event = build_create_server_event(name: "Owned Server")

      post federation_create_server_path, params: { event: event }, as: :json

      server = Server.last
      expect(server.owner.remote?).to be true
      expect(server.owner.remote_user_detail.nostr_public_key).to eq(public_key)
    end

    it "returns an invite code for the new server" do
      event = build_create_server_event(name: "Invite Server")

      post federation_create_server_path, params: { event: event }, as: :json

      body = JSON.parse(response.body)
      invite = Invite.find_by(code: body["invite_code"])
      expect(invite).to be_present
      expect(invite.server.name).to eq("Invite Server")
    end

    it "reuses existing remote user for same pubkey" do
      remote_user = create(:remote_user, nostr_public_key: public_key, home_instance: "home.chat")
      shadow = create(:user, :remote, remote_user_detail: remote_user)

      event = build_create_server_event(name: "Reuse Server")

      expect {
        post federation_create_server_path, params: { event: event }, as: :json
      }.not_to change(RemoteUser, :count)

      expect(response).to have_http_status(:created)
    end

    context "validation errors" do
      it "rejects missing event parameter" do
        post federation_create_server_path, as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to include("Missing signed event")
      end

      it "rejects wrong event kind" do
        event = build_create_server_event(name: "Bad Kind")
        event[:kind] = 1

        # Recompute id for wrong kind
        serialized = [0, event[:pubkey], event[:created_at], 1, event[:tags], event[:content]]
        event[:id] = Digest::SHA256.hexdigest(JSON.generate(serialized))

        post federation_create_server_path, params: { event: event }, as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to include("Invalid event kind")
      end

      it "rejects missing d-tag" do
        content = { name: "Test" }.to_json
        tags = [["relay", "wss://home.chat"]]
        created_at = Time.now.to_i

        serialized = [0, public_key, created_at, 30078, tags, content]
        id = Digest::SHA256.hexdigest(JSON.generate(serialized))

        message_bin = [id].pack("H*")
        private_key_bin = [private_key].pack("H*")
        signature = Schnorr.sign(message_bin, private_key_bin)
        sig_hex = signature.encode.unpack1("H*")

        event = {
          id: id, pubkey: public_key, created_at: created_at,
          kind: 30078, tags: tags, content: content, sig: sig_hex
        }

        post federation_create_server_path, params: { event: event }, as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to include("d-tag")
      end

      it "rejects tampered event ID" do
        event = build_create_server_event(name: "Tampered")
        event[:id] = "0" * 64

        post federation_create_server_path, params: { event: event }, as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to include("Event ID mismatch")
      end

      it "rejects invalid signature" do
        event = build_create_server_event(name: "Bad Sig")
        event[:sig] = "0" * 128

        post federation_create_server_path, params: { event: event }, as: :json

        expect(response).to have_http_status(:unauthorized)
        body = JSON.parse(response.body)
        expect(body["error"]).to include("Invalid signature")
      end

      it "rejects expired events" do
        content = { name: "Old", username: "testuser" }.to_json
        tags = [["d", "create_server"], ["relay", "wss://home.chat"]]
        created_at = 20.minutes.ago.to_i

        serialized = [0, public_key, created_at, 30078, tags, content]
        id = Digest::SHA256.hexdigest(JSON.generate(serialized))

        message_bin = [id].pack("H*")
        private_key_bin = [private_key].pack("H*")
        signature = Schnorr.sign(message_bin, private_key_bin)
        sig_hex = signature.encode.unpack1("H*")

        event = {
          id: id, pubkey: public_key, created_at: created_at,
          kind: 30078, tags: tags, content: content, sig: sig_hex
        }

        post federation_create_server_path, params: { event: event }, as: :json

        expect(response).to have_http_status(:bad_request)
        body = JSON.parse(response.body)
        expect(body["error"]).to include("timestamp out of range")
      end
    end

    context "federation controls" do
      it "rejects when federation is closed" do
        InstanceConfig.current.update!(federation_mode: "closed")

        event = build_create_server_event(name: "Blocked Server")

        post federation_create_server_path, params: { event: event }, as: :json

        expect(response).to have_http_status(:forbidden)
        body = JSON.parse(response.body)
        expect(body["error"]).to include("Federation is closed")
      end

      it "rejects when remote joins are locked down" do
        InstanceConfig.current.update!(lockdown_remote_joins: true)

        event = build_create_server_event(name: "Locked Down")

        post federation_create_server_path, params: { event: event }, as: :json

        expect(response).to have_http_status(:forbidden)
      end

      it "rejects when home instance is blocklisted" do
        admin = create(:user, :confirmed, :admin)
        InstanceBlocklist.create!(domain: "home.chat", blocked_by: admin, blocked_at: Time.current)

        event = build_create_server_event(name: "Blocklisted", home_relay: "wss://home.chat")

        post federation_create_server_path, params: { event: event }, as: :json

        expect(response).to have_http_status(:forbidden)
        body = JSON.parse(response.body)
        expect(body["error"]).to include("blocked")
      end
    end
  end
end
