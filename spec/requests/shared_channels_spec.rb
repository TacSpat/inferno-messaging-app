require 'rails_helper'

RSpec.describe "SharedChannels", type: :request do
  let(:user) { create(:user, :confirmed) }
  let(:server) { create(:server, owner: user) }
  let(:channel) { server.channels.first }

  before do
    sign_in user
    stub_action_cable
  end

  describe "POST /servers/:server_id/channels/:id/bridge" do
    it "enables sharing on a channel" do
      post bridge_server_channel_path(server, channel), params: {
        relay_url: "wss://relay.example.com"
      }

      expect(response).to redirect_to(server_channel_path(server, channel))
      channel.reload
      expect(channel.shared?).to be true
      expect(channel.nostr_relay_url).to eq("wss://relay.example.com")
      expect(channel.nostr_group_id).to be_present
    end

    it "bridges to an external group when group_id is provided" do
      post bridge_server_channel_path(server, channel), params: {
        relay_url: "wss://relay.example.com",
        group_id: "external-group-123"
      }

      channel.reload
      expect(channel.nostr_group_id).to eq("external-group-123")
    end

    it "requires relay_url" do
      post bridge_server_channel_path(server, channel), params: {}

      expect(response).to redirect_to(edit_server_channel_path(server, channel))
      expect(flash[:alert]).to include("Relay URL is required")
    end

    it "allows any authenticated user" do
      other_user = create(:user, :confirmed)
      sign_in other_user

      post bridge_server_channel_path(server, channel), params: {
        relay_url: "wss://relay.example.com"
      }
      expect(response).to redirect_to(server_channel_path(server, channel))
    end
  end

  describe "DELETE /servers/:server_id/channels/:id/unbridge" do
    it "disables sharing on a channel" do
      channel.enable_sharing!(relay_url: "wss://relay.example.com")

      delete unbridge_server_channel_path(server, channel)

      expect(response).to redirect_to(server_channel_path(server, channel))
      channel.reload
      expect(channel.shared?).to be false
      expect(channel.nostr_group_id).to be_nil
    end
  end
end
