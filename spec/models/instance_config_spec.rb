require 'rails_helper'

RSpec.describe InstanceConfig, type: :model do
  subject(:config) { InstanceConfig.current }

  describe "validations" do
    it { should validate_inclusion_of(:pruning_strategy).in_array(InstanceConfig::PRUNING_STRATEGIES) }
    it { should validate_inclusion_of(:federation_mode).in_array(InstanceConfig::FEDERATION_MODES) }

    %i[max_users max_servers max_servers_per_user max_channels_per_server
       max_categories_per_server max_members_per_server max_roles_per_server
       max_upload_size_mb max_storage_per_user_mb message_retention_days
       attachment_retention_days].each do |attr|
      it { should validate_numericality_of(attr).only_integer.is_greater_than_or_equal_to(0) }
    end
  end

  describe ".current" do
    it "returns an existing config" do
      # before(:each) already creates one via first_or_create!
      existing = InstanceConfig.first
      expect(InstanceConfig.current).to eq(existing)
    end

    it "creates a config if none exists" do
      InstanceConfig.delete_all
      expect { InstanceConfig.current }.to change(InstanceConfig, :count).by(1)
    end

    it "always returns the same record" do
      expect(InstanceConfig.current.id).to eq(InstanceConfig.current.id)
    end
  end

  describe "#lockdown?" do
    it "returns true when lockdown_enabled is true" do
      config.update!(lockdown_enabled: true)
      expect(config.lockdown?).to be true
    end

    it "returns false when lockdown_enabled is false" do
      config.update!(lockdown_enabled: false)
      expect(config.lockdown?).to be false
    end
  end

  describe "#remote_auth_blocked?" do
    it "returns true when full lockdown is enabled" do
      config.update!(lockdown_enabled: true, lockdown_remote_auth: false)
      expect(config.remote_auth_blocked?).to be true
    end

    it "returns true when granular lockdown_remote_auth is enabled" do
      config.update!(lockdown_enabled: false, lockdown_remote_auth: true)
      expect(config.remote_auth_blocked?).to be true
    end

    it "returns false when neither is enabled" do
      config.update!(lockdown_enabled: false, lockdown_remote_auth: false)
      expect(config.remote_auth_blocked?).to be false
    end
  end

  describe "#local_signups_blocked?" do
    it "returns true when full lockdown is enabled" do
      config.update!(lockdown_enabled: true)
      expect(config.local_signups_blocked?).to be true
    end

    it "returns true when granular lockdown_local_signups is enabled" do
      config.update!(lockdown_enabled: false, lockdown_local_signups: true)
      expect(config.local_signups_blocked?).to be true
    end
  end

  describe "#invite_creation_blocked?" do
    it "returns true when full lockdown is enabled" do
      config.update!(lockdown_enabled: true)
      expect(config.invite_creation_blocked?).to be true
    end

    it "returns true when granular lockdown_invite_creation is enabled" do
      config.update!(lockdown_enabled: false, lockdown_invite_creation: true)
      expect(config.invite_creation_blocked?).to be true
    end
  end

  describe "#emergency_lockdown!" do
    it "enables all lockdown flags" do
      config.emergency_lockdown!
      config.reload

      expect(config.lockdown_enabled).to be true
      expect(config.lockdown_remote_auth).to be true
      expect(config.lockdown_remote_joins).to be true
      expect(config.lockdown_local_signups).to be true
      expect(config.lockdown_invite_creation).to be true
    end
  end

  describe "#lift_lockdown!" do
    it "disables all lockdown flags" do
      config.emergency_lockdown!
      config.lift_lockdown!
      config.reload

      expect(config.lockdown_enabled).to be false
      expect(config.lockdown_remote_auth).to be false
      expect(config.lockdown_remote_joins).to be false
      expect(config.lockdown_local_signups).to be false
      expect(config.lockdown_invite_creation).to be false
    end
  end

  describe "federation mode predicates" do
    it "federation_open? returns true for open mode" do
      config.update!(federation_mode: "open")
      expect(config.federation_open?).to be true
      expect(config.federation_closed?).to be false
    end

    it "federation_closed? returns true for closed mode" do
      config.update!(federation_mode: "closed")
      expect(config.federation_closed?).to be true
      expect(config.federation_open?).to be false
    end
  end

  describe "#unlimited?" do
    it "returns true when setting is zero" do
      config.update!(max_users: 0)
      expect(config.unlimited?(:max_users)).to be true
    end

    it "returns false when setting is non-zero" do
      config.update!(max_users: 100)
      expect(config.unlimited?(:max_users)).to be false
    end
  end

  describe "limit checks" do
    before { stub_action_cable }

    it "#user_limit_reached? returns true when at limit" do
      config.update!(max_users: 1)
      create(:user, :confirmed)
      expect(config.user_limit_reached?).to be true
    end

    it "#user_limit_reached? returns false when unlimited" do
      config.update!(max_users: 0)
      expect(config.user_limit_reached?).to be false
    end

    it "#server_limit_reached? returns true when at limit" do
      config.update!(max_servers: 1)
      create(:server)
      expect(config.server_limit_reached?).to be true
    end
  end
end
