require 'rails_helper'

RSpec.describe Channel, "hierarchy" do
  include NostrTestHelpers

  let(:owner) { create(:user, :confirmed) }
  let(:server) { create(:server, owner: owner) }

  before do
    stub_relay_service
    stub_action_cable
  end

  describe "dependent: :nullify on child_channels" do
    it "nullifies children's parent_channel_id when parent is destroyed" do
      parent = create(:channel, server: server, channel_type: :voice, name: "parent")
      child1 = create(:channel, server: server, channel_type: :voice, name: "child1", parent_channel: parent)
      child2 = create(:channel, server: server, channel_type: :voice, name: "child2", parent_channel: parent)

      parent.destroy

      expect(child1.reload.parent_channel_id).to be_nil
      expect(child2.reload.parent_channel_id).to be_nil
    end

    it "does not destroy children when parent is destroyed" do
      parent = create(:channel, server: server, channel_type: :voice, name: "parent")
      child = create(:channel, server: server, channel_type: :voice, name: "child", parent_channel: parent)

      parent.destroy

      expect(Channel.exists?(child.id)).to eq(true)
    end
  end

  describe "nesting" do
    it "tracks ancestor_channels bottom-up" do
      root = create(:channel, server: server, channel_type: :voice, name: "root")
      mid = create(:channel, server: server, channel_type: :voice, name: "mid", parent_channel: root)
      leaf = create(:channel, server: server, channel_type: :voice, name: "leaf", parent_channel: mid)

      expect(leaf.ancestor_channels).to eq([mid, root])
    end
  end
end
