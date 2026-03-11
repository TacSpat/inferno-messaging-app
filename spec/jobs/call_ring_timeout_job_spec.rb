require 'rails_helper'

RSpec.describe CallRingTimeoutJob, type: :job do
  let(:user) { create(:user, :confirmed) }
  let(:conversation) { create(:conversation) }

  before do
    allow(ConversationChannel).to receive(:broadcast_to)
  end

  describe "#perform" do
    context "when call is ringing" do
      let(:call) { conversation.calls.create!(initiated_by: user, status: "ringing") }

      it "ends the call and creates system message" do
        expect { described_class.new.perform(call.id) }
          .to change(Message, :count).by(1)

        call.reload
        expect(call.status).to eq("ended")
        expect(call.ended_at).to be_present

        system_msg = Message.last
        expect(system_msg.system_message).to be true
        expect(system_msg.content).to include("missed")
      end
    end

    context "when call is already accepted" do
      let(:call) { conversation.calls.create!(initiated_by: user, status: "active", started_at: Time.current) }

      it "does nothing" do
        expect { described_class.new.perform(call.id) }
          .not_to change(Message, :count)

        expect(call.reload.status).to eq("active")
      end
    end

    context "when call does not exist" do
      it "does not raise an error" do
        expect { described_class.new.perform(-1) }.not_to raise_error
      end
    end
  end
end
