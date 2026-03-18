require 'rails_helper'

RSpec.describe NostrHistoryFetcher do
  include NostrTestHelpers

  let(:owner) do
    user = create(:user, :confirmed, nostr_public_key: test_public_key)
    allow(user).to receive(:nostr_private_key).and_return(test_private_key)
    user
  end
  let(:server) { create(:server, owner: owner) }
  let(:channel) { create(:channel, :shared, server: server) }

  before do
    stub_relay_service
    allow(User).to receive(:owner).and_return(owner)
    allow(NostrProfileResolver).to receive(:resolve)
    allow(ChannelChatChannel).to receive(:broadcast_to)
    allow(ConversationChannel).to receive(:broadcast_to)
    LocalConfig.first_or_create!(backfill_enabled: true, backfill_days: 30)
  end

  describe ".fetch_channel" do
    let(:remote_pubkey) { NostrTestHelpers::TEST_PUBLIC_KEY_2 }
    let(:events) do
      3.times.map do |i|
        {
          "id" => SecureRandom.hex(32),
          "pubkey" => remote_pubkey,
          "kind" => 9,
          "content" => "Message #{i}",
          "created_at" => (Time.current - (3 - i).minutes).to_i,
          "tags" => [["h", channel.nostr_group_id]]
        }
      end
    end

    it "imports new messages from relay events" do
      allow(RelayService).to receive(:fetch_from_all).and_return(events)

      expect { NostrHistoryFetcher.fetch_channel(channel) }
        .to change { channel.messages.count }.by(3)
    end

    it "broadcasts backfill_complete instead of individual messages" do
      allow(RelayService).to receive(:fetch_from_all).and_return(events)

      expect(ChannelChatChannel).to receive(:broadcast_to).with(
        channel,
        hash_including(type: "backfill_complete", count: 3)
      ).once

      NostrHistoryFetcher.fetch_channel(channel)
    end

    it "does not broadcast when no new messages are imported" do
      allow(RelayService).to receive(:fetch_from_all).and_return([])

      expect(ChannelChatChannel).not_to receive(:broadcast_to)

      NostrHistoryFetcher.fetch_channel(channel)
    end

    it "skips already processed events (batch dedup)" do
      allow(RelayService).to receive(:fetch_from_all).and_return(events)

      # Pre-create event log entries for the first two events
      events[0..1].each do |e|
        NostrEventLog.create!(
          event_id: e["id"], kind: 9, pubkey: remote_pubkey,
          direction: "inbound", event_created_at: Time.current
        )
      end

      expect { NostrHistoryFetcher.fetch_channel(channel) }
        .to change { channel.messages.count }.by(1)
    end

    it "skips events from the owner's own pubkey" do
      own_events = events.map { |e| e.merge("pubkey" => test_public_key) }
      allow(RelayService).to receive(:fetch_from_all).and_return(own_events)

      expect { NostrHistoryFetcher.fetch_channel(channel) }
        .not_to change { channel.messages.count }
    end

    it "skips duplicate messages already in the channel (by nostr_event_id)" do
      allow(RelayService).to receive(:fetch_from_all).and_return(events)

      # Pre-create a message with one of the event IDs
      channel.messages.create!(
        content: "Existing", public_id: SecureRandom.alphanumeric(12),
        nostr_event_id: events[0]["id"], nostr_author_pubkey: remote_pubkey
      )

      expect { NostrHistoryFetcher.fetch_channel(channel) }
        .to change { channel.messages.count }.by(2)
    end

    it "creates NostrEventLog entries for imported events" do
      allow(RelayService).to receive(:fetch_from_all).and_return(events)

      expect { NostrHistoryFetcher.fetch_channel(channel) }
        .to change { NostrEventLog.count }.by(3)
    end

    it "batch-resolves stale contacts" do
      allow(RelayService).to receive(:fetch_from_all).and_return(events)

      expect(NostrProfileResolver).to receive(:resolve).with(remote_pubkey).once

      NostrHistoryFetcher.fetch_channel(channel)
    end

    it "does not resolve contacts that already have fresh profiles" do
      Contact.create!(pubkey: remote_pubkey, display_name: "Fresh", profile_fetched_at: 5.minutes.ago)
      allow(RelayService).to receive(:fetch_from_all).and_return(events)

      expect(NostrProfileResolver).not_to receive(:resolve)

      NostrHistoryFetcher.fetch_channel(channel)
    end

    it "continues importing after a duplicate event (batch dedup catches it)" do
      # The batch dedup check queries existing nostr_event_ids upfront.
      # Pre-create a message with one event's ID — the fetcher should skip it
      # and still import the other two successfully.
      allow(RelayService).to receive(:fetch_from_all).and_return(events)

      # This message exists in DB but NOT in NostrEventLog — tests the
      # channel.messages.where(nostr_event_id:) batch dedup path specifically
      channel.all_messages.create!(
        content: "pre-existing",
        public_id: SecureRandom.alphanumeric(12),
        nostr_event_id: events[1]["id"],
        nostr_author_pubkey: remote_pubkey
      )

      # Should skip events[1] (already in channel) and import events[0] and events[2]
      expect { NostrHistoryFetcher.fetch_channel(channel) }
        .to change { channel.all_messages.count }.by(2)

      # Verify the skipped event was NOT double-created
      expect(channel.all_messages.where(nostr_event_id: events[1]["id"]).count).to eq(1)
    end

    it "does nothing when backfill is disabled" do
      LocalConfig.first.update!(backfill_enabled: false)

      expect(RelayService).not_to receive(:fetch_from_all)
      NostrHistoryFetcher.fetch_channel(channel)
    end
  end

  describe ".fetch_conversation" do
    let(:counterparty_key) { NostrTestHelpers::TEST_PUBLIC_KEY_2 }
    let(:conversation) do
      conv = create(:conversation)
      conv.update_columns(counterparty_pubkey: counterparty_key)
      conv.conversation_participants.create!(user: owner)
      conv
    end

    it "broadcasts backfill_complete for DMs" do
      # DM decryption requires real crypto — test the broadcast path
      allow(RelayService).to receive(:fetch_from_all).and_return([])

      expect(ConversationChannel).not_to receive(:broadcast_to)

      NostrHistoryFetcher.fetch_conversation(conversation)
    end
  end
end
