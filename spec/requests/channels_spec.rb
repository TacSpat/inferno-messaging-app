require "rails_helper"

RSpec.describe "Channels", type: :request do
  let(:user) { create(:user, :confirmed) }
  let!(:server) { create(:server, owner: user) }
  let(:channel) { server.channels.find_by(name: "general") }

  before { sign_in user }

  describe "GET /servers/:server_id/channels/:id" do
    it "shows the channel with message list" do
      get server_channel_path(server.public_id, channel.public_id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(channel.name)
    end

    it "requires membership" do
      non_member = create(:user, :confirmed)
      sign_in non_member

      get server_channel_path(server.public_id, channel.public_id)
      expect(response).to redirect_to(root_path)
    end

    it "loads existing messages" do
      message = channel.messages.create!(content: "Test message here", user: user)

      get server_channel_path(server.public_id, channel.public_id)
      expect(response.body).to include("Test message here")
    end
  end

  describe "GET /servers/:server_id/channels/new" do
    it "shows the channel creation form for owner" do
      get new_server_channel_path(server.public_id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Create Channel")
    end

    it "requires manage_channels permission" do
      regular_user = create(:user, :confirmed)
      server.server_memberships.create!(user: regular_user)
      sign_in regular_user

      get new_server_channel_path(server.public_id)
      expect(response).to redirect_to(server_channel_path(server, server.channels.ordered.first))
    end
  end

  describe "POST /servers/:server_id/channels" do
    it "creates a channel and redirects" do
      expect {
        post server_channels_path(server.public_id), params: { channel: { name: "announcements", channel_type: "text" } }
      }.to change(server.channels, :count).by(1)

      new_channel = server.channels.find_by(name: "announcements")
      expect(response).to redirect_to(server_channel_path(server.public_id, new_channel.public_id))
    end

    it "validates channel name" do
      expect {
        post server_channels_path(server.public_id), params: { channel: { name: "", channel_type: "text" } }
      }.not_to change(Channel, :count)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "requires manage_channels permission" do
      regular_user = create(:user, :confirmed)
      server.server_memberships.create!(user: regular_user)
      sign_in regular_user

      post server_channels_path(server.public_id), params: { channel: { name: "test", channel_type: "text" } }
      expect(response).to redirect_to(server_channel_path(server, server.channels.ordered.first))
    end
  end
end
