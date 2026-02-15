require 'rails_helper'

RSpec.describe NostrGroupPublishJob, type: :job do
  include NostrTestHelpers

  let(:server) { create(:server) }
  let(:channel) { create(:channel, :shared, server: server) }
  let(:user) { create(:user, :confirmed, nostr_public_key: test_public_key) }

  before do
    stub_relay_service
    stub_action_cable
    # Stub nostr_private_key on any User instance to return our test key
    allow_any_instance_of(User).to receive(:nostr_private_key).and_return(test_private_key)
  end

  describe "#perform" do
    it "publishes Kind 9 event with h-tag to the channel's relay" do
      message = Message.create!(
        content: "Hello federation!",
        user: user,
        channel: channel,
        public_id: SecureRandom.alphanumeric(12)
      )

      expect(RelayService).to receive(:publish_to_relay).with(
        anything,
        anything
      ).and_return({ success: true, message: "OK" })

      NostrGroupPublishJob.perform_now(message.id)
    end

    it "creates an outbound NostrEventLog" do
      message = Message.create!(
        content: "Hello!",
        user: user,
        channel: channel,
        public_id: SecureRandom.alphanumeric(12)
      )

      expect {
        NostrGroupPublishJob.perform_now(message.id)
      }.to change(NostrEventLog, :count).by(1)

      log = NostrEventLog.last
      expect(log.direction).to eq("outbound")
      expect(log.kind).to eq(9)
      expect(log.channel).to eq(channel)
    end

    it "skips non-shared channels" do
      regular_channel = create(:channel, server: server, shared: false)
      message = Message.create!(
        content: "Hello!",
        user: user,
        channel: regular_channel,
        public_id: SecureRandom.alphanumeric(12)
      )

      expect(RelayService).not_to receive(:publish_to_relay)
      NostrGroupPublishJob.perform_now(message.id)
    end

    it "skips messages from remote users" do
      remote = create(:remote_user)
      shadow = User.create!(
        username: "remote_test",
        email: "remote@test.com",
        password: SecureRandom.hex(32),
        remote: true,
        remote_user_detail: remote,
        public_id: SecureRandom.alphanumeric(12),
        confirmed_at: Time.current
      )

      message = Message.create!(
        content: "Hello!",
        user: shadow,
        channel: channel,
        public_id: SecureRandom.alphanumeric(12)
      )

      expect(RelayService).not_to receive(:publish_to_relay)
      NostrGroupPublishJob.perform_now(message.id)
    end

    it "handles missing message gracefully" do
      expect { NostrGroupPublishJob.perform_now(999999) }.not_to raise_error
    end
  end
end
