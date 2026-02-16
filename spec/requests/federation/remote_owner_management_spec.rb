require 'rails_helper'

RSpec.describe "Remote Owner Server Management", type: :request do
  # Simulate a remote user who owns a server (created via federation API)
  let(:remote_detail) { create(:remote_user, home_instance: "home.chat", username: "remote_owner") }
  let(:remote_owner) { create(:user, :remote, username: "remote_owner", remote_user_detail: remote_detail) }
  let!(:server) { create(:server, owner: remote_owner) }
  let(:general_channel) { server.channels.find_by(name: "general") }
  let(:regular_member) { create(:user, :confirmed) }

  before do
    sign_in remote_owner
    # Add a regular member for kick/ban tests
    server.server_memberships.create!(user: regular_member, joined_at: Time.current)
  end

  describe "Server Settings" do
    it "can view server overview" do
      get server_settings_overview_path(server)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(server.name)
    end

    it "can update server name" do
      patch server_settings_update_overview_path(server), params: {
        server: { name: "Renamed by Remote Owner" }
      }
      expect(response).to redirect_to(server_settings_overview_path(server))
      expect(server.reload.name).to eq("Renamed by Remote Owner")
    end

    it "can update server description" do
      patch server_settings_update_overview_path(server), params: {
        server: { description: "Updated description" }
      }
      expect(server.reload.description).to eq("Updated description")
    end
  end

  describe "Member Management" do
    it "can view members page" do
      get server_settings_members_path(server)
      expect(response).to have_http_status(:ok)
    end

    it "can kick a member" do
      membership = server.server_memberships.find_by(user: regular_member)
      expect {
        delete server_settings_kick_member_path(server, membership)
      }.to change(server.server_memberships, :count).by(-1)
      expect(response).to redirect_to(server_settings_members_path(server))
    end

    it "can update a member's nickname" do
      membership = server.server_memberships.find_by(user: regular_member)
      patch server_settings_update_member_path(server, membership), params: {
        nickname: "New Nickname"
      }, as: :json
      expect(response).to have_http_status(:ok)
      expect(membership.reload.nickname).to eq("New Nickname")
    end
  end

  describe "Channel Management" do
    it "can create a channel" do
      expect {
        post server_channels_path(server), params: {
          channel: { name: "remote-owner-channel", channel_type: "text" }
        }
      }.to change(server.channels, :count).by(1)
    end

    it "can view a channel" do
      get server_channel_path(server, general_channel)
      expect(response).to have_http_status(:ok)
    end

    it "can edit a channel" do
      get edit_server_channel_path(server, general_channel)
      expect(response).to have_http_status(:ok)
    end

    it "can update a channel" do
      patch server_channel_path(server, general_channel), params: {
        channel: { name: "renamed-by-remote" }
      }
      expect(general_channel.reload.name).to eq("renamed-by-remote")
    end

    it "can delete a channel" do
      extra = server.channels.create!(name: "deleteable", channel_type: :text, position: 1)
      expect {
        delete server_channel_path(server, extra)
      }.to change(server.channels, :count).by(-1)
    end
  end

  describe "Role Management" do
    it "can view roles" do
      get server_settings_roles_path(server)
      expect(response).to have_http_status(:ok)
    end

    it "can create a role" do
      expect {
        post server_roles_path(server), params: {
          role: { name: "Moderator", color: "#ff0000" }
        }, as: :json
      }.to change(server.roles, :count).by(1)
    end

    it "can update a role" do
      role = server.roles.find_by(name: "Admin")
      patch server_role_path(server, role), params: {
        color: "#00ff00"
      }, as: :json
      expect(response).to have_http_status(:ok)
      expect(role.reload.color).to eq("#00ff00")
    end

    it "can delete a non-system role" do
      role = server.roles.create!(name: "Temp", position: 5)
      expect {
        delete server_role_path(server, role), as: :json
      }.to change(server.roles, :count).by(-1)
    end
  end

  describe "Invite Management" do
    it "can view invites" do
      get server_settings_invites_path(server)
      expect(response).to have_http_status(:ok)
    end

    it "can create an invite" do
      expect {
        post server_settings_create_invite_path(server), params: {
          expires_in: "7d", max_uses: 10
        }
      }.to change(server.invites, :count).by(1)
    end

    it "can revoke an invite" do
      invite = server.invites.first
      delete server_settings_destroy_invite_path(server), params: { invite_id: invite.id }
      expect(invite.reload.active).to be false
    end
  end

  describe "Ban Management" do
    it "can view bans" do
      get server_settings_bans_path(server)
      expect(response).to have_http_status(:ok)
    end

    it "can ban a member" do
      expect {
        post server_settings_create_ban_path(server), params: {
          user_id: regular_member.public_id,
          reason: "Banned by remote owner"
        }
      }.to change(server.bans, :count).by(1)
    end
  end

  describe "Audit Log" do
    it "can view audit log" do
      get server_settings_audit_log_path(server)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "Server Deletion" do
    it "can delete their own server" do
      expect {
        delete server_path(server)
      }.to change(Server, :count).by(-1)
      expect(response).to redirect_to(root_path)
    end
  end
end
