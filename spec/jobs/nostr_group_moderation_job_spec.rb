require 'rails_helper'

RSpec.describe NostrGroupModerationJob, type: :job do
  include NostrTestHelpers

  let(:server) { create(:server) }
  let(:channel) { create(:channel, :shared, server: server) }
  let(:moderator) { create(:user, :confirmed, nostr_public_key: test_public_key) }

  before do
    stub_relay_service
    stub_action_cable
    allow_any_instance_of(User).to receive(:nostr_private_key).and_return(test_private_key)
  end

  describe "Kind 9005: delete event" do
    it "publishes a delete event to the channel's relay" do
      expect(RelayService).to receive(:publish_to_all).with(anything).and_return({})

      NostrGroupModerationJob.perform_now(
        :delete_event,
        channel_id: channel.id,
        moderator_id: moderator.id,
        target_event_id: SecureRandom.hex(32),
        reason: "Spam"
      )
    end

    it "skips when target_event_id is blank" do
      expect(RelayService).not_to receive(:publish_to_all)

      NostrGroupModerationJob.perform_now(
        :delete_event,
        channel_id: channel.id,
        moderator_id: moderator.id,
        target_event_id: nil
      )
    end
  end

  describe "Kind 9001: remove user" do
    it "publishes a remove-user event to the channel's relay" do
      target_pubkey = SecureRandom.hex(32)

      expect(RelayService).to receive(:publish_to_all).with(anything).and_return({})

      NostrGroupModerationJob.perform_now(
        :remove_user,
        channel_id: channel.id,
        moderator_id: moderator.id,
        target_pubkey: target_pubkey,
        reason: "Violation"
      )
    end

    it "skips when target_pubkey is blank" do
      expect(RelayService).not_to receive(:publish_to_all)

      NostrGroupModerationJob.perform_now(
        :remove_user,
        channel_id: channel.id,
        moderator_id: moderator.id,
        target_pubkey: nil
      )
    end
  end

  describe "channel requirements" do
    it "skips when channel doesn't exist" do
      expect(RelayService).not_to receive(:publish_to_all)

      NostrGroupModerationJob.perform_now(
        :delete_event,
        channel_id: 999999,
        moderator_id: moderator.id,
        target_event_id: SecureRandom.hex(32)
      )
    end
  end

  describe "moderator requirements" do
    it "skips when moderator has no nostr key" do
      no_key_mod = create(:user, :confirmed)
      no_key_mod.update_column(:nostr_public_key, nil)
      allow(User).to receive(:find_by).with(id: no_key_mod.id).and_return(no_key_mod)

      expect(RelayService).not_to receive(:publish_to_all)

      NostrGroupModerationJob.perform_now(
        :delete_event,
        channel_id: channel.id,
        moderator_id: no_key_mod.id,
        target_event_id: SecureRandom.hex(32)
      )
    end
  end
end
