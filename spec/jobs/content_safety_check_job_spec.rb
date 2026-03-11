require 'rails_helper'

RSpec.describe ContentSafetyCheckJob, type: :job do
  describe "#perform" do
    context "with a valid message" do
      let(:message) { create(:message) }
      let(:filter) { instance_double(ContentSafetyFilter) }

      it "calls ContentSafetyFilter#check!" do
        allow(ContentSafetyFilter).to receive(:new).with(message).and_return(filter)
        allow(filter).to receive(:check!)

        described_class.new.perform(message.id)

        expect(filter).to have_received(:check!)
      end
    end

    context "when message does not exist" do
      it "does not raise an error" do
        expect { described_class.new.perform(-1) }.not_to raise_error
      end
    end

    context "when message is already hidden" do
      let(:message) { create(:message) }

      before do
        message.update_columns(hidden_at: Time.current, hidden_reason: "test")
      end

      it "does not call ContentSafetyFilter" do
        expect(ContentSafetyFilter).not_to receive(:new)
        described_class.new.perform(message.id)
      end
    end
  end
end
