require 'rails_helper'

RSpec.describe PruneMessagesJob, type: :job do
  let(:config) { LocalConfig.current }

  describe "#perform" do
    context "when pruning is disabled" do
      before { config.update!(pruning_strategy: "none") }

      it "does nothing" do
        old_msg = create(:message, created_at: 1.year.ago)
        described_class.new.perform
        expect(Message.exists?(old_msg.id)).to be true
      end
    end

    context "with time_based strategy" do
      before do
        config.update!(
          pruning_strategy: "time_based",
          message_retention_days: 30,
          prune_channel_messages: true,
          prune_dm_messages: true
        )
      end

      it "deletes messages older than retention period" do
        old_msg = create(:message, created_at: 60.days.ago)
        recent_msg = create(:message, created_at: 1.day.ago)

        described_class.new.perform

        expect(Message.exists?(old_msg.id)).to be false
        expect(Message.exists?(recent_msg.id)).to be true
      end

      it "preserves hidden messages (evidence)" do
        old_hidden = create(:message, created_at: 60.days.ago)
        old_hidden.update_columns(hidden_at: Time.current, hidden_reason: "test")

        described_class.new.perform

        expect(Message.exists?(old_hidden.id)).to be true
      end

      it "respects keep_pinned_messages flag" do
        config.update!(keep_pinned_messages: true)
        pinned_msg = create(:message, created_at: 60.days.ago, pinned: true)

        described_class.new.perform

        expect(Message.exists?(pinned_msg.id)).to be true
      end
    end
  end
end
