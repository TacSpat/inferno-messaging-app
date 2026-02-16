require 'rails_helper'

RSpec.describe RelayConnection, type: :model do
  describe "validations" do
    subject { build(:relay_connection) }

    it { should validate_presence_of(:url) }
    it { should validate_uniqueness_of(:url) }
    it { should validate_inclusion_of(:status).in_array(RelayConnection::STATUSES) }

    it "requires a WebSocket URL format" do
      relay = build(:relay_connection, url: "https://example.com")
      expect(relay).not_to be_valid
      expect(relay.errors[:url]).to include("must be a WebSocket URL (wss:// or ws://)")
    end

    it "accepts wss:// URLs" do
      relay = build(:relay_connection, url: "wss://relay.example.com")
      expect(relay).to be_valid
    end

    it "accepts ws:// URLs" do
      relay = build(:relay_connection, url: "ws://relay.example.com")
      expect(relay).to be_valid
    end
  end

  describe "scopes" do
    let!(:active_relay) { create(:relay_connection, status: "active") }
    let!(:disabled_relay) { create(:relay_connection, :disabled) }
    let!(:error_relay) { create(:relay_connection, :error) }

    it ".active returns only active relays" do
      expect(RelayConnection.active).to contain_exactly(active_relay)
    end

    it ".connectable returns only active relays" do
      expect(RelayConnection.connectable).to contain_exactly(active_relay)
    end
  end

  describe "#mark_connected!" do
    it "updates status and last_connected_at" do
      relay = create(:relay_connection, :error)
      relay.mark_connected!
      relay.reload

      expect(relay.status).to eq("active")
      expect(relay.last_connected_at).to be_present
      expect(relay.last_error_message).to be_nil
    end
  end

  describe "#mark_error!" do
    it "updates status and error info" do
      relay = create(:relay_connection)
      relay.mark_error!("Connection refused")
      relay.reload

      expect(relay.status).to eq("error")
      expect(relay.last_error_at).to be_present
      expect(relay.last_error_message).to eq("Connection refused")
    end
  end

  describe "#disable!" do
    it "sets status to disabled" do
      relay = create(:relay_connection)
      relay.disable!
      expect(relay.reload.status).to eq("disabled")
    end
  end

  describe "#enable!" do
    it "sets status to active and clears error" do
      relay = create(:relay_connection, :error)
      relay.enable!
      relay.reload

      expect(relay.status).to eq("active")
      expect(relay.last_error_message).to be_nil
    end
  end

  describe ".find_or_create_for_relay" do
    it "creates an active relay connection for a valid wss:// URL" do
      relay = RelayConnection.find_or_create_for_relay("wss://relay.home.com")

      expect(relay).to be_persisted
      expect(relay.url).to eq("wss://relay.home.com")
      expect(relay.status).to eq("active")
    end

    it "creates an active relay connection for a valid ws:// URL" do
      relay = RelayConnection.find_or_create_for_relay("ws://relay.home.com")

      expect(relay).to be_persisted
      expect(relay.url).to eq("ws://relay.home.com")
      expect(relay.status).to eq("active")
    end

    it "returns existing relay if already present" do
      existing = create(:relay_connection, url: "wss://relay.home.com")
      result = RelayConnection.find_or_create_for_relay("wss://relay.home.com")

      expect(result.id).to eq(existing.id)
      expect(RelayConnection.where(url: "wss://relay.home.com").count).to eq(1)
    end

    it "returns nil for blank URL" do
      expect(RelayConnection.find_or_create_for_relay("")).to be_nil
      expect(RelayConnection.find_or_create_for_relay(nil)).to be_nil
    end

    it "returns nil for non-WebSocket URL" do
      expect(RelayConnection.find_or_create_for_relay("https://example.com")).to be_nil
      expect(RelayConnection.find_or_create_for_relay("ftp://relay.com")).to be_nil
    end

    it "strips whitespace from URLs" do
      relay = RelayConnection.find_or_create_for_relay("  wss://relay.home.com  ")

      expect(relay).to be_persisted
      expect(relay.url).to eq("wss://relay.home.com")
    end
  end

  describe "status predicates" do
    it "#active? returns true for active status" do
      expect(build(:relay_connection, status: "active").active?).to be true
    end

    it "#disabled? returns true for disabled status" do
      expect(build(:relay_connection, status: "disabled").disabled?).to be true
    end

    it "#error? returns true for error status" do
      expect(build(:relay_connection, status: "error").error?).to be true
    end
  end
end
