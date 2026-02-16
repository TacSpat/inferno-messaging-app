require 'rails_helper'

RSpec.describe FederationService do
  include NostrTestHelpers

  let(:private_key) { test_private_key }
  let(:public_key) { test_public_key }
  let(:user) do
    user = create(:user, :confirmed, nostr_public_key: public_key)
    allow(user).to receive(:nostr_private_key).and_return(private_key)
    user
  end

  describe ".create_remote_server" do
    let(:instance_url) { "https://remote.chat" }
    let(:success_response) do
      {
        server_id: "srv_abc123",
        invite_code: "inv12345",
        server_name: "My Remote Server",
        instance_domain: "remote.chat"
      }.to_json
    end

    before do
      stub_request(:post, "https://remote.chat/federation/create_server")
        .to_return(status: 201, body: success_response, headers: { "Content-Type" => "application/json" })
    end

    it "sends a signed event to the remote instance" do
      FederationService.create_remote_server(
        user: user, instance_url: instance_url,
        name: "My Remote Server", description: "A test"
      )

      expect(WebMock).to have_requested(:post, "https://remote.chat/federation/create_server")
        .with { |req|
          body = JSON.parse(req.body)
          event = body["event"]
          event["kind"] == 30078 &&
            event["pubkey"] == public_key &&
            event["tags"].any? { |t| t == ["d", "create_server"] }
        }
    end

    it "creates a local RemoteServerReference" do
      expect {
        FederationService.create_remote_server(
          user: user, instance_url: instance_url,
          name: "My Remote Server"
        )
      }.to change(RemoteServerReference, :count).by(1)

      ref = RemoteServerReference.last
      expect(ref.user).to eq(user)
      expect(ref.remote_instance_url).to eq("https://remote.chat")
      expect(ref.remote_server_id).to eq("srv_abc123")
      expect(ref.invite_code).to eq("inv12345")
      expect(ref.name).to eq("My Remote Server")
    end

    it "returns the RemoteServerReference" do
      result = FederationService.create_remote_server(
        user: user, instance_url: instance_url,
        name: "My Remote Server"
      )

      expect(result).to be_a(RemoteServerReference)
      expect(result.remote_server_id).to eq("srv_abc123")
    end

    it "normalizes instance URL without protocol" do
      stub_request(:post, "https://remote.chat/federation/create_server")
        .to_return(status: 201, body: success_response, headers: { "Content-Type" => "application/json" })

      FederationService.create_remote_server(
        user: user, instance_url: "remote.chat",
        name: "My Remote Server"
      )

      expect(WebMock).to have_requested(:post, "https://remote.chat/federation/create_server")
    end

    it "strips trailing slash from instance URL" do
      stub_request(:post, "https://remote.chat/federation/create_server")
        .to_return(status: 201, body: success_response, headers: { "Content-Type" => "application/json" })

      ref = FederationService.create_remote_server(
        user: user, instance_url: "https://remote.chat/",
        name: "My Remote Server"
      )

      expect(ref.remote_instance_url).to eq("https://remote.chat")
    end

    it "reuses existing reference for same server" do
      existing = create(:remote_server_reference,
        user: user,
        remote_instance_url: "https://remote.chat",
        remote_server_id: "srv_abc123",
        name: "Old Name"
      )

      expect {
        FederationService.create_remote_server(
          user: user, instance_url: instance_url,
          name: "My Remote Server"
        )
      }.not_to change(RemoteServerReference, :count)

      expect(existing.reload.name).to eq("My Remote Server")
      expect(existing.invite_code).to eq("inv12345")
    end

    context "error handling" do
      it "raises FederationError when user has no Nostr keypair" do
        user_without_key = create(:user, :confirmed)
        allow(user_without_key).to receive(:nostr_private_key).and_return(nil)

        expect {
          FederationService.create_remote_server(
            user: user_without_key, instance_url: instance_url,
            name: "No Key Server"
          )
        }.to raise_error(FederationService::FederationError, /Nostr keypair/)
      end

      it "raises FederationError on non-201 response" do
        stub_request(:post, "https://remote.chat/federation/create_server")
          .to_return(status: 403, body: { error: "Federation is closed" }.to_json)

        expect {
          FederationService.create_remote_server(
            user: user, instance_url: instance_url,
            name: "Rejected Server"
          )
        }.to raise_error(FederationService::FederationError, /403.*Federation is closed/)
      end

      it "raises FederationError on 500 error" do
        stub_request(:post, "https://remote.chat/federation/create_server")
          .to_return(status: 500, body: "Internal Server Error")

        expect {
          FederationService.create_remote_server(
            user: user, instance_url: instance_url,
            name: "Error Server"
          )
        }.to raise_error(FederationService::FederationError, /500/)
      end
    end
  end
end
