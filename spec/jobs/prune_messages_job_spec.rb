require 'rails_helper'

RSpec.describe PruneMessagesJob, type: :job do
  let(:config) { InstanceConfig.current }

  before do
    config.update!(pruning_strategy: "time_based", message_retention_days: 30)
  end

  describe "legal hold exclusions" do
    let(:server) { create(:server) }
    let(:channel) { server.channels.first || create(:channel, server: server) }
    let(:held_user) { create(:user, :confirmed) }
    let(:normal_user) { create(:user, :confirmed) }

    before do
      # Old messages from both users
      @held_msg = Message.create!(
        user: held_user, channel: channel, content: "held message",
        public_id: SecureRandom.alphanumeric(12), created_at: 60.days.ago
      )
      @normal_msg = Message.create!(
        user: normal_user, channel: channel, content: "normal message",
        public_id: SecureRandom.alphanumeric(12), created_at: 60.days.ago
      )
    end

    it "excludes messages from users under legal hold" do
      create(:legal_hold, holdable: held_user)

      described_class.perform_now

      expect(Message.exists?(@held_msg.id)).to be true
      expect(Message.exists?(@normal_msg.id)).to be false
    end

    it "excludes messages in channels under legal hold" do
      create(:legal_hold, :on_channel, holdable: channel)

      described_class.perform_now

      expect(Message.exists?(@held_msg.id)).to be true
      expect(Message.exists?(@normal_msg.id)).to be true
    end

    it "excludes messages in channels belonging to servers under legal hold" do
      create(:legal_hold, :on_server, holdable: server)

      described_class.perform_now

      expect(Message.exists?(@held_msg.id)).to be true
      expect(Message.exists?(@normal_msg.id)).to be true
    end

    it "prunes normally when no legal holds exist" do
      described_class.perform_now

      expect(Message.exists?(@held_msg.id)).to be false
      expect(Message.exists?(@normal_msg.id)).to be false
    end

    it "prunes after hold is lifted" do
      hold = create(:legal_hold, holdable: held_user)
      hold.lift!

      described_class.perform_now

      expect(Message.exists?(@held_msg.id)).to be false
    end
  end
end
