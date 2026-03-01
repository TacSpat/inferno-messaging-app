require 'rails_helper'

RSpec.describe RelayService do
  describe ".publish_to_all" do
    it "returns empty hash when no active relays" do
      create(:relay_connection, :disabled)

      results = RelayService.publish_to_all(JSON.generate({ id: "test" }))
      expect(results).to eq({})
    end
  end

  describe ".fetch_from_all" do
    it "returns empty array when no relays are active" do
      results = RelayService.fetch_from_all({ kinds: [ 0 ] })
      expect(results).to eq([])
    end
  end
end
