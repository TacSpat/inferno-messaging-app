require 'rails_helper'

RSpec.describe "Admin::InstanceConfigs", type: :request do
  describe "GET /admin/instance_config" do
    it "requires admin access" do
      user = sign_in_as_user
      get admin_instance_config_path
      expect(response).to redirect_to(root_path)
    end

    it "shows config page for admin" do
      sign_in_as_admin
      get admin_instance_config_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /admin/instance_config" do
    it "updates instance settings" do
      sign_in_as_admin
      patch admin_instance_config_path, params: {
        instance_config: {
          instance_name: "New Name",
          federation_mode: "closed",
          max_users: 100
        }
      }

      expect(response).to redirect_to(admin_instance_config_path)
      config = InstanceConfig.current.reload
      expect(config.instance_name).to eq("New Name")
      expect(config.federation_mode).to eq("closed")
      expect(config.max_users).to eq(100)
    end

    it "rejects invalid values" do
      sign_in_as_admin
      patch admin_instance_config_path, params: {
        instance_config: {
          federation_mode: "invalid"
        }
      }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST /admin/instance_config/emergency_lockdown" do
    it "activates emergency lockdown" do
      sign_in_as_admin
      post emergency_lockdown_admin_instance_config_path

      expect(response).to redirect_to(admin_instance_config_path)
      config = InstanceConfig.current.reload
      expect(config.lockdown_enabled).to be true
      expect(config.lockdown_remote_auth).to be true
    end

    it "requires admin access" do
      sign_in_as_user
      post emergency_lockdown_admin_instance_config_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST /admin/instance_config/lift_lockdown" do
    it "lifts all lockdowns" do
      sign_in_as_admin
      InstanceConfig.current.emergency_lockdown!

      post lift_lockdown_admin_instance_config_path

      expect(response).to redirect_to(admin_instance_config_path)
      config = InstanceConfig.current.reload
      expect(config.lockdown_enabled).to be false
      expect(config.lockdown_remote_auth).to be false
    end
  end
end
