require 'rails_helper'

RSpec.describe "Settings - Connected Instances", type: :request do
  let(:user) { create(:user, :confirmed) }

  before { sign_in user }

  describe "GET /settings/account" do
    it "shows the Connected Instances heading" do
      get user_settings_account_path
      expect(response.body).to include("Connected Instances")
    end

    it "shows the home instance domain" do
      get user_settings_account_path
      expect(response.body).to include(Rails.application.config.x.instance_domain)
      expect(response.body).to include("Home instance")
    end

    it "shows a remote instance when user has remote server references" do
      create(:remote_server_reference, user: user, remote_instance_url: "https://cool.chat", name: "Cool Server")
      get user_settings_account_path
      expect(response.body).to include("cool.chat")
    end

    it "shows server name under a remote instance" do
      create(:remote_server_reference, user: user, remote_instance_url: "https://cool.chat", name: "Cool Server")
      get user_settings_account_path
      expect(response.body).to include("Cool Server")
    end

    it "shows empty state message when no remote connections" do
      get user_settings_account_path
      expect(response.body).to include("No remote instance connections yet")
    end
  end
end
