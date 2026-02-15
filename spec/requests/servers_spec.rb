require "rails_helper"

RSpec.describe "Servers", type: :request do
  let(:user) { create(:user, :confirmed) }

  describe "GET /servers/new" do
    it "shows the new server form when signed in" do
      sign_in user
      get new_server_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Create Server")
    end

    it "redirects to login when not signed in" do
      get new_server_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "POST /servers" do
    context "when signed in" do
      before { sign_in user }

      it "creates a server with defaults and redirects to #general" do
        expect {
          post servers_path, params: { server: { name: "My Server" } }
        }.to change(Server, :count).by(1)

        server = Server.last
        expect(server.name).to eq("My Server")
        expect(server.owner).to eq(user)
        expect(server.channels.exists?(name: "general")).to be true
        expect(server.roles.count).to eq(3)
        expect(server.members).to include(user)
        expect(response).to redirect_to(server_channel_path(server, server.channels.first))
      end

      it "rejects a blank name" do
        expect {
          post servers_path, params: { server: { name: "" } }
        }.not_to change(Server, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    it "requires authentication" do
      post servers_path, params: { server: { name: "My Server" } }
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "DELETE /servers/:id" do
    let!(:server) { create(:server, owner: user) }

    it "allows the owner to delete" do
      sign_in user
      expect {
        delete server_path(server.public_id)
      }.to change(Server, :count).by(-1)
      expect(response).to redirect_to(root_path)
    end

    it "denies non-owner deletion" do
      other_user = create(:user, :confirmed)
      server.server_memberships.create!(user: other_user)
      sign_in other_user

      expect {
        delete server_path(server.public_id)
      }.to raise_error(Pundit::NotAuthorizedError)
    end
  end
end
