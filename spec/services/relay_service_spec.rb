require 'rails_helper'

RSpec.describe RelayService do
  before do
    stub_relay_service
  end

  describe ".publish_to_all" do
    it "queries active relays" do
      allow(RelayService).to receive(:publish_to_all).and_call_original
      allow(RelayService).to receive(:publish_to_relay).and_return({ success: true, message: "OK" })

      relay1 = create(:relay_connection, status: "active")
      relay2 = create(:relay_connection, status: "active")
      _disabled = create(:relay_connection, :disabled)

      results = RelayService.publish_to_all({ id: "test" })
      expect(results.keys).to contain_exactly(relay1.url, relay2.url)
    end

    it "returns empty hash when no active relays" do
      allow(RelayService).to receive(:publish_to_all).and_call_original
      create(:relay_connection, :disabled)

      results = RelayService.publish_to_all({ id: "test" })
      expect(results).to eq({})
    end
  end

  describe ".fetch_from_all" do
    it "deduplicates events by event id" do
      allow(RelayService).to receive(:fetch_from_all).and_call_original

      event = { "id" => "event1", "kind" => 0, "content" => "test" }

      # Simulate both relays returning the same event
      allow(RelayService).to receive(:fetch_from_relay).and_return([ event ])

      create(:relay_connection, status: "active")
      create(:relay_connection, status: "active")

      results = RelayService.fetch_from_all({ kinds: [ 0 ] })
      expect(results.length).to eq(1)
      expect(results.first["id"]).to eq("event1")
    end

    it "returns empty array when no relays are active" do
      allow(RelayService).to receive(:fetch_from_all).and_call_original
      results = RelayService.fetch_from_all({ kinds: [ 0 ] })
      expect(results).to eq([])
    end
  end
end
