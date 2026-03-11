require 'rails_helper'

RSpec.describe AuthorityReportGenerator do
  let(:reporter) { create(:user, :confirmed) }

  describe "#generate" do
    context "with a channel message" do
      let(:message) do
        msg = create(:message, content: "Test message content")
        allow(LocalConfig.current).to receive(:safety_image_hash_enabled).and_return(false)
        msg.hide!(reporter, reason: "test")
        msg
      end

      it "returns a string with expected sections" do
        report = described_class.new(message, category: "threats", reporter: reporter).generate

        expect(report).to include("REPORT FOR LAW ENFORCEMENT")
        expect(report).to include("MESSAGE DETAILS")
        expect(report).to include("MESSAGE CONTENT")
        expect(report).to include("Test message content")
        expect(report).to include("REPORTER INFORMATION")
        expect(report).to include(reporter.username)
        expect(report).to include("Credible Threats of Violence")
      end
    end

    context "with a conversation message" do
      let(:conversation) { create(:conversation, kind: :direct) }
      let(:message) do
        msg = create(:message, content: "DM content", channel: nil, conversation: conversation)
        allow(LocalConfig.current).to receive(:safety_image_hash_enabled).and_return(false)
        msg.hide!(reporter, reason: "test")
        msg
      end

      it "includes conversation context" do
        report = described_class.new(message, category: "threats", reporter: reporter).generate
        expect(report).to include("Direct Message")
      end
    end

    context "with hidden attachments" do
      let(:message) do
        msg = create(:message, content: "With attachment")
        allow(LocalConfig.current).to receive(:safety_image_hash_enabled).and_return(false)
        msg.hide!(reporter, reason: "test")
        create(:hidden_attachment_record, message: msg, purged_by: reporter,
               original_filename: "evidence.jpg", content_type: "image/jpeg", byte_size: 2048)
        msg
      end

      it "includes attachment metadata" do
        report = described_class.new(message, category: "csam", reporter: reporter).generate
        expect(report).to include("ATTACHMENT METADATA")
        expect(report).to include("evidence.jpg")
      end
    end

    %w[csam threats terrorism other_illegal].each do |category|
      it "generates valid report for #{category}" do
        message = create(:message, content: "content")
        allow(LocalConfig.current).to receive(:safety_image_hash_enabled).and_return(false)
        message.hide!(reporter, reason: "test")

        report = described_class.new(message, category: category, reporter: reporter).generate
        expect(report).to be_a(String)
        expect(report.length).to be > 100
      end
    end
  end
end
