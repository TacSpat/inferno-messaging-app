require 'rails_helper'

RSpec.describe "Admin::RelayConnections", type: :request do
  describe "POST /admin/relay_connections" do
    it "creates a relay with valid URL" do
      sign_in_as_admin

      expect {
        post admin_relay_connections_path, params: { url: "wss://relay.example.com" }
      }.to change(RelayConnection, :count).by(1)

      expect(response).to redirect_to(admin_instance_config_path)
      expect(RelayConnection.last.url).to eq("wss://relay.example.com")
      expect(RelayConnection.last.status).to eq("active")
    end

    it "rejects invalid URL" do
      sign_in_as_admin

      post admin_relay_connections_path, params: { url: "https://not-a-websocket.com" }

      expect(response).to redirect_to(admin_instance_config_path)
      expect(flash[:alert]).to be_present
    end

    it "rejects duplicate URLs" do
      sign_in_as_admin
      create(:relay_connection, url: "wss://relay.example.com")

      post admin_relay_connections_path, params: { url: "wss://relay.example.com" }

      expect(response).to redirect_to(admin_instance_config_path)
      expect(flash[:alert]).to be_present
    end

    it "requires admin access" do
      sign_in_as_user
      post admin_relay_connections_path, params: { url: "wss://relay.example.com" }
      expect(response).to redirect_to(root_path)
    end
  end

  describe "DELETE /admin/relay_connections/:id" do
    it "removes a relay" do
      sign_in_as_admin
      relay = create(:relay_connection)

      expect {
        delete admin_relay_connection_path(relay)
      }.to change(RelayConnection, :count).by(-1)

      expect(response).to redirect_to(admin_instance_config_path)
    end
  end

  describe "POST /admin/relay_connections/:id/toggle" do
    it "disables an active relay" do
      sign_in_as_admin
      relay = create(:relay_connection, status: "active")

      post toggle_admin_relay_connection_path(relay)

      expect(relay.reload.status).to eq("disabled")
      expect(response).to redirect_to(admin_instance_config_path)
    end

    it "enables a disabled relay" do
      sign_in_as_admin
      relay = create(:relay_connection, :disabled)

      post toggle_admin_relay_connection_path(relay)

      expect(relay.reload.status).to eq("active")
      expect(response).to redirect_to(admin_instance_config_path)
    end
  end
end
