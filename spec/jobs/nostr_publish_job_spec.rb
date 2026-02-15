require 'rails_helper'

RSpec.describe NostrPublishJob, type: :job do
  include NostrTestHelpers

  let(:user) do
    user = create(:user, :confirmed, nostr_public_key: test_public_key)
    allow(user).to receive(:nostr_private_key).and_return(test_private_key)
    user
  end

  before do
    stub_relay_service
    stub_action_cable
    allow(User).to receive(:find).with(user.id).and_return(user)
  end

  describe "Kind 0: profile event" do
    it "publishes profile metadata to relays" do
      expect(RelayService).to receive(:publish_to_all).with(anything)
      NostrPublishJob.perform_now(user.id, :profile)
    end

    it "updates nostr_profile_published_at" do
      NostrPublishJob.perform_now(user.id, :profile)
      user.reload
      expect(user.nostr_profile_published_at).to be_present
    end
  end

  describe "Kind 3: contacts event" do
    it "publishes contacts list to relays" do
      expect(RelayService).to receive(:publish_to_all).with(anything)
      NostrPublishJob.perform_now(user.id, :contacts)
    end

    it "updates nostr_contacts_published_at" do
      NostrPublishJob.perform_now(user.id, :contacts)
      user.reload
      expect(user.nostr_contacts_published_at).to be_present
    end
  end

  describe "Kind 10002: relay list event" do
    it "publishes relay list to relays" do
      expect(RelayService).to receive(:publish_to_all).with(anything)
      NostrPublishJob.perform_now(user.id, :relay_list)
    end
  end

  describe "skipping remote users" do
    it "does not publish for remote users" do
      remote_user = create(:user, :confirmed, remote: true)
      allow(User).to receive(:find).with(remote_user.id).and_return(remote_user)

      expect(RelayService).not_to receive(:publish_to_all)
      NostrPublishJob.perform_now(remote_user.id, :profile)
    end
  end

  describe "unknown event type" do
    it "logs a warning and returns" do
      expect(RelayService).not_to receive(:publish_to_all)
      NostrPublishJob.perform_now(user.id, :unknown_type)
    end
  end
end
