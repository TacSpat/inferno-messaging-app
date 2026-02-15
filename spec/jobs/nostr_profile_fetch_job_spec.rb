require 'rails_helper'

RSpec.describe NostrProfileFetchJob, type: :job do
  let(:pubkey) { SecureRandom.hex(32) }
  let!(:remote_user) { create(:remote_user, nostr_public_key: pubkey, username: "original") }

  before do
    stub_relay_service
  end

  describe "#perform" do
    it "fetches Kind 0 events and updates remote user profile" do
      profile_event = {
        "id" => SecureRandom.hex(32),
        "kind" => 0,
        "pubkey" => pubkey,
        "created_at" => Time.now.to_i,
        "content" => {
          "name" => "alice",
          "display_name" => "Alice Wonderland",
          "about" => "Hello!",
          "picture" => "https://example.com/avatar.png"
        }.to_json
      }

      allow(RelayService).to receive(:fetch_from_all).and_return([profile_event])

      NostrProfileFetchJob.perform_now(pubkey)
      remote_user.reload

      expect(remote_user.username).to eq("alice")
      expect(remote_user.display_name).to eq("Alice Wonderland")
      expect(remote_user.bio).to eq("Hello!")
      expect(remote_user.avatar_url).to eq("https://example.com/avatar.png")
    end

    it "updates shadow user display_name" do
      # Create shadow user
      RemoteUser.find_or_create_from_auth(
        public_key: pubkey,
        home_instance: "remote.chat",
        username: "original"
      )
      remote_user.reload

      profile_event = {
        "id" => SecureRandom.hex(32),
        "kind" => 0,
        "pubkey" => pubkey,
        "created_at" => Time.now.to_i,
        "content" => { "display_name" => "New Display Name" }.to_json
      }

      allow(RelayService).to receive(:fetch_from_all).and_return([profile_event])

      NostrProfileFetchJob.perform_now(pubkey)
      remote_user.reload
      expect(remote_user.shadow_user&.display_name).to eq("New Display Name")
    end

    it "handles missing remote user gracefully" do
      expect { NostrProfileFetchJob.perform_now("nonexistent_pubkey") }.not_to raise_error
    end

    it "handles empty relay results gracefully" do
      allow(RelayService).to receive(:fetch_from_all).and_return([])
      expect { NostrProfileFetchJob.perform_now(pubkey) }.not_to raise_error
    end

    it "uses the most recent event when multiple are returned" do
      old_event = {
        "id" => SecureRandom.hex(32),
        "kind" => 0,
        "pubkey" => pubkey,
        "created_at" => 1.hour.ago.to_i,
        "content" => { "name" => "old_name" }.to_json
      }
      new_event = {
        "id" => SecureRandom.hex(32),
        "kind" => 0,
        "pubkey" => pubkey,
        "created_at" => Time.now.to_i,
        "content" => { "name" => "new_name" }.to_json
      }

      allow(RelayService).to receive(:fetch_from_all).and_return([old_event, new_event])

      NostrProfileFetchJob.perform_now(pubkey)
      remote_user.reload
      expect(remote_user.username).to eq("new_name")
    end
  end
end
