require 'rails_helper'

RSpec.describe NostrReportPublishJob, type: :job do
  include NostrTestHelpers

  before do
    stub_relay_service
    stub_instance_nostr_config
  end

  describe "#perform" do
    let(:report) { create(:moderation_report, report_type: "spam", reason: "Spamming channels") }

    it "publishes Kind 1984 NIP-56 report event" do
      expect(RelayService).to receive(:publish_to_all).with(anything)
      NostrReportPublishJob.perform_now(report.id)
    end

    it "includes p tag with reported pubkey and report type" do
      published_event = nil
      allow(RelayService).to receive(:publish_to_all) do |event|
        published_event = event
        {}
      end

      NostrReportPublishJob.perform_now(report.id)

      event_data = JSON.parse(published_event) if published_event.is_a?(String)
      event_data ||= published_event

      tags = event_data["tags"] || event_data[:tags]
      p_tag = tags.find { |t| t[0] == "p" }
      expect(p_tag).to be_present
      expect(p_tag[1]).to eq(report.reported_pubkey)
      expect(p_tag[2]).to eq("spam")
    end

    it "includes e tag when reported_event_id is present" do
      report_with_event = create(:moderation_report,
        reported_event_id: "event123",
        report_type: "harassment"
      )

      published_event = nil
      allow(RelayService).to receive(:publish_to_all) do |event|
        published_event = event
        {}
      end

      NostrReportPublishJob.perform_now(report_with_event.id)

      event_data = JSON.parse(published_event) if published_event.is_a?(String)
      event_data ||= published_event

      tags = event_data["tags"] || event_data[:tags]
      e_tag = tags.find { |t| t[0] == "e" }
      expect(e_tag).to be_present
      expect(e_tag[1]).to eq("event123")
    end

    it "includes L and l MOD tags" do
      published_event = nil
      allow(RelayService).to receive(:publish_to_all) do |event|
        published_event = event
        {}
      end

      NostrReportPublishJob.perform_now(report.id)

      event_data = JSON.parse(published_event) if published_event.is_a?(String)
      event_data ||= published_event

      tags = event_data["tags"] || event_data[:tags]
      expect(tags).to include([ "L", "MOD" ])
      expect(tags).to include([ "l", "spam", "MOD" ])
    end

    it "uses instance keypair for signing" do
      published_event = nil
      allow(RelayService).to receive(:publish_to_all) do |event|
        published_event = event
        {}
      end

      NostrReportPublishJob.perform_now(report.id)

      event_data = JSON.parse(published_event) if published_event.is_a?(String)
      event_data ||= published_event

      pubkey = event_data["pubkey"] || event_data[:pubkey]
      expect(pubkey).to eq(instance_public_key)
    end

    it "skips if no instance key is configured" do
      Rails.application.config.nostr = {
        instance_private_key: nil,
        instance_public_key: nil
      }

      expect(RelayService).not_to receive(:publish_to_all)
      NostrReportPublishJob.perform_now(report.id)
    end

    it "handles missing report gracefully" do
      expect { NostrReportPublishJob.perform_now(999999) }.not_to raise_error
    end
  end
end
