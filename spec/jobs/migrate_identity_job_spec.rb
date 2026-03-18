require 'rails_helper'

RSpec.describe MigrateIdentityJob do
  include NostrTestHelpers

  let(:user) do
    u = create(:user, :confirmed, nostr_public_key: test_public_key)
    allow(u).to receive(:nostr_private_key).and_return(test_private_key)
    u
  end

  before do
    stub_relay_service
    stub_action_cable
    allow(MigrationChannel).to receive(:broadcast_to)
    allow(NostrSyncService).to receive_message_chain(:new, :sync_contacts)
    allow(NostrSyncService).to receive_message_chain(:new, :sync_group_history)
    allow(NostrProfileResolver).to receive(:resolve_batch)
  end

  describe "progress broadcasting" do
    it "broadcasts progress via MigrationChannel" do
      expect(MigrationChannel).to receive(:broadcast_to).with(
        user, hash_including(step: "contacts", progress: 10)
      )
      expect(MigrationChannel).to receive(:broadcast_to).with(
        user, hash_including(step: "complete", progress: 100)
      ).at_least(:once)
      # Allow other broadcasts
      allow(MigrationChannel).to receive(:broadcast_to)

      MigrateIdentityJob.perform_now(user.id)
    end

    it "broadcasts completion with redirect_url" do
      allow(MigrationChannel).to receive(:broadcast_to)

      expect(MigrationChannel).to receive(:broadcast_to).with(
        user, hash_including(step: "complete", progress: 100, redirect_url: anything)
      )

      MigrateIdentityJob.perform_now(user.id)
    end

    it "also writes progress to Rails cache for initial poll fallback" do
      allow(MigrationChannel).to receive(:broadcast_to)
      allow(ActionCable.server).to receive(:broadcast)

      # Use memory store for this test to verify cache writes
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)

      MigrateIdentityJob.perform_now(user.id)

      cached = memory_store.read("migrate_identity:#{user.id}")
      expect(cached[:step]).to eq("complete")
      expect(cached[:progress]).to eq(100)
    end

    it "broadcasts failure on error" do
      # NostrSyncService.sync_contacts is called directly (not wrapped in rescue)
      # at line 29 of perform — raising here triggers the top-level rescue
      allow(NostrSyncService).to receive(:new).and_raise(RuntimeError, "Sync service crashed")
      allow(MigrationChannel).to receive(:broadcast_to)

      # Use memory store so we can verify cache writes
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)

      MigrateIdentityJob.perform_now(user.id)

      # Verify the failure was broadcast via ActionCable
      expect(MigrationChannel).to have_received(:broadcast_to).with(
        user, hash_including(step: "failed", progress: 0)
      )

      # Verify cache also shows failure
      cached = memory_store.read("migrate_identity:#{user.id}")
      expect(cached[:step]).to eq("failed")
      expect(cached[:error]).to include("Sync service crashed")
    end
  end
end
