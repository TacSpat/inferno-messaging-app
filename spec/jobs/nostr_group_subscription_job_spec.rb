require 'rails_helper'

RSpec.describe NostrGroupSubscriptionJob, type: :job do
  include NostrTestHelpers

  let(:server) { create(:server) }
  let(:channel) { create(:channel, :shared, server: server) }

  before do
    stub_relay_service
    stub_action_cable
  end

  describe "#perform" do
    it "processes inbound Kind 9 events and creates messages" do
      remote_pubkey = SecureRandom.hex(32)
      event_id = SecureRandom.hex(32)

      event = {
        "id" => event_id,
        "kind" => 9,
        "pubkey" => remote_pubkey,
        "content" => "Hello from remote!",
        "sig" => "a" * 128,
        "created_at" => Time.now.to_i,
        "tags" => [ [ "h", channel.nostr_group_id ] ]
      }

      allow(RelayService).to receive(:fetch_from_relay).and_return([ event ])
      allow(NostrEventService).to receive(:verify_schnorr_signature).and_return(true)

      expect {
        NostrGroupSubscriptionJob.perform_now
      }.to change(Message, :count).by(1)

      message = Message.last
      expect(message.content).to eq("Hello from remote!")
      expect(message.user.remote?).to be true
    end

    it "creates shadow users for unknown remote pubkeys" do
      remote_pubkey = SecureRandom.hex(32)
      event = {
        "id" => SecureRandom.hex(32),
        "kind" => 9,
        "pubkey" => remote_pubkey,
        "content" => "Hello!",
        "sig" => "a" * 128,
        "created_at" => Time.now.to_i,
        "tags" => [ [ "h", channel.nostr_group_id ] ]
      }

      allow(RelayService).to receive(:fetch_from_relay).and_return([ event ])
      allow(NostrEventService).to receive(:verify_schnorr_signature).and_return(true)

      expect {
        NostrGroupSubscriptionJob.perform_now
      }.to change(RemoteUser, :count).by(1)
    end

    it "deduplicates already-processed events" do
      remote_pubkey = SecureRandom.hex(32)
      event_id = SecureRandom.hex(32)

      # Pre-create an event log
      create(:nostr_event_log, event_id: event_id, channel: channel)

      event = {
        "id" => event_id,
        "kind" => 9,
        "pubkey" => remote_pubkey,
        "content" => "Duplicate!",
        "sig" => "a" * 128,
        "created_at" => Time.now.to_i,
        "tags" => [ [ "h", channel.nostr_group_id ] ]
      }

      allow(RelayService).to receive(:fetch_from_relay).and_return([ event ])

      expect {
        NostrGroupSubscriptionJob.perform_now
      }.not_to change(Message, :count)
    end

    it "skips events from local users" do
      local_user = create(:user, :confirmed)

      event = {
        "id" => SecureRandom.hex(32),
        "kind" => 9,
        "pubkey" => local_user.nostr_public_key,
        "content" => "Local message",
        "sig" => "a" * 128,
        "created_at" => Time.now.to_i,
        "tags" => [ [ "h", channel.nostr_group_id ] ]
      }

      allow(RelayService).to receive(:fetch_from_relay).and_return([ event ])

      expect {
        NostrGroupSubscriptionJob.perform_now
      }.not_to change(Message, :count)
    end

    it "verifies event signatures" do
      remote_pubkey = SecureRandom.hex(32)
      event = {
        "id" => SecureRandom.hex(32),
        "kind" => 9,
        "pubkey" => remote_pubkey,
        "content" => "Bad sig",
        "sig" => "bad" * 42 + "ab",
        "created_at" => Time.now.to_i,
        "tags" => [ [ "h", channel.nostr_group_id ] ]
      }

      allow(RelayService).to receive(:fetch_from_relay).and_return([ event ])
      allow(NostrEventService).to receive(:verify_schnorr_signature)
        .and_raise(NostrEventService::InvalidSignature, "Bad signature")

      expect {
        NostrGroupSubscriptionJob.perform_now
      }.not_to change(Message, :count)
    end

    it "creates an inbound NostrEventLog entry" do
      remote_pubkey = SecureRandom.hex(32)
      event = {
        "id" => SecureRandom.hex(32),
        "kind" => 9,
        "pubkey" => remote_pubkey,
        "content" => "Hello!",
        "sig" => "a" * 128,
        "created_at" => Time.now.to_i,
        "tags" => [ [ "h", channel.nostr_group_id ] ]
      }

      allow(RelayService).to receive(:fetch_from_relay).and_return([ event ])
      allow(NostrEventService).to receive(:verify_schnorr_signature).and_return(true)

      expect {
        NostrGroupSubscriptionJob.perform_now
      }.to change(NostrEventLog, :count).by(1)

      log = NostrEventLog.last
      expect(log.direction).to eq("inbound")
      expect(log.kind).to eq(9)
    end

    it "does nothing when no shared channels exist" do
      Channel.where(shared: true).destroy_all
      expect(RelayService).not_to receive(:fetch_from_relay)
      NostrGroupSubscriptionJob.perform_now
    end
  end
end
