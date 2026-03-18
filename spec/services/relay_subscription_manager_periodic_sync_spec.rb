require 'rails_helper'

RSpec.describe RelaySubscriptionManager, "periodic sync" do
  include NostrTestHelpers

  let(:owner) { create(:user, :confirmed) }
  let(:rsm) { RelaySubscriptionManager.instance }

  before do
    stub_relay_service
    stub_action_cable
    allow(NostrServerSyncService).to receive_message_chain(:new, :sync_all)
  end

  describe "#run_periodic_sync" do
    it "skips servers synced within the last hour" do
      server = create(:server, owner: owner, nostr_group_id: "test-group",
                       last_synced_at: 30.minutes.ago)

      rsm.send(:run_periodic_sync)

      expect(NostrServerSyncService).not_to have_received(:new).with("test-group")
    end

    it "syncs servers not synced recently" do
      server = create(:server, owner: owner, nostr_group_id: "test-group",
                       last_synced_at: 2.hours.ago)

      rsm.send(:run_periodic_sync)

      expect(NostrServerSyncService).to have_received(:new).with("test-group")
    end

    it "syncs servers that have never been synced" do
      server = create(:server, owner: owner, nostr_group_id: "test-group",
                       last_synced_at: nil)

      rsm.send(:run_periodic_sync)

      expect(NostrServerSyncService).to have_received(:new).with("test-group")
    end

    it "updates last_synced_at after successful sync" do
      server = create(:server, owner: owner, nostr_group_id: "test-group",
                       last_synced_at: nil)

      rsm.send(:run_periodic_sync)

      server.reload
      expect(server.last_synced_at).to be_within(5.seconds).of(Time.current)
    end

    it "skips servers without nostr_group_id" do
      server = create(:server, owner: owner)
      server.update_column(:nostr_group_id, nil)

      rsm.send(:run_periodic_sync)

      expect(NostrServerSyncService).not_to have_received(:new)
    end
  end
end
