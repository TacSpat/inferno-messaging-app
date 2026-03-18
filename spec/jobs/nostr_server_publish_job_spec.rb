require 'rails_helper'

RSpec.describe NostrServerPublishJob do
  include NostrTestHelpers

  let(:owner) do
    user = create(:user, :confirmed, nostr_public_key: test_public_key)
    allow(user).to receive(:nostr_private_key).and_return(test_private_key)
    user
  end
  let(:server) { create(:server, owner: owner) }

  before do
    stub_relay_service
    stub_action_cable
    allow(BlossomClientService).to receive(:upload_attachment).and_return("https://blossom.example.com/test.png")
  end

  describe "build_structure_tags" do
    it "includes voice settings in channel tags" do
      channel = create(:channel, server: server, channel_type: :voice,
                       voice_bitrate: 128000, voice_user_limit: 10, video_enabled: true)

      job = NostrServerPublishJob.new
      job.instance_variable_set(:@server, server.reload)
      job.instance_variable_set(:@user, owner)
      tags = job.send(:build_structure_tags)

      ch_tag = tags.find { |t| t[0] == "ch" && t[1] == channel.public_id }
      expect(ch_tag).to be_present

      # t[14] = voice_bitrate, t[15] = voice_user_limit, t[16] = video_enabled, t[17] = post_only
      expect(ch_tag[14]).to eq("128000")
      expect(ch_tag[15]).to eq("10")
      expect(ch_tag[16]).to eq("true")
      expect(ch_tag[17]).to eq("false")
    end

    it "includes post_only flag in channel tags" do
      channel = create(:channel, server: server, post_only: true)

      job = NostrServerPublishJob.new
      job.instance_variable_set(:@server, server.reload)
      job.instance_variable_set(:@user, owner)
      tags = job.send(:build_structure_tags)

      ch_tag = tags.find { |t| t[0] == "ch" && t[1] == channel.public_id }
      expect(ch_tag[17]).to eq("true")
    end

    it "includes parent_channel and sidechat references" do
      voice_channel = create(:channel, server: server, channel_type: :voice, name: "voice-1")
      text_channel = create(:channel, server: server, name: "text-1")
      child_channel = create(:channel, server: server, channel_type: :voice, name: "child-voice",
                             parent_channel: voice_channel)
      voice_channel.update!(sidechat_channel: text_channel)

      job = NostrServerPublishJob.new
      job.instance_variable_set(:@server, server.reload)
      job.instance_variable_set(:@user, owner)
      tags = job.send(:build_structure_tags)

      # Check parent reference on child
      child_tag = tags.find { |t| t[0] == "ch" && t[1] == child_channel.public_id }
      expect(child_tag[13]).to eq(voice_channel.public_id)

      # Check sidechat reference on voice channel
      voice_tag = tags.find { |t| t[0] == "ch" && t[1] == voice_channel.public_id }
      expect(voice_tag[12]).to eq(text_channel.public_id)
    end

    it "includes default values for channels without voice settings" do
      channel = create(:channel, server: server)

      job = NostrServerPublishJob.new
      job.instance_variable_set(:@server, server.reload)
      job.instance_variable_set(:@user, owner)
      tags = job.send(:build_structure_tags)

      ch_tag = tags.find { |t| t[0] == "ch" && t[1] == channel.public_id }
      expect(ch_tag[14]).to eq("64000")  # default voice_bitrate
      expect(ch_tag[15]).to eq("0")      # default voice_user_limit
      expect(ch_tag[16]).to eq("false")  # default video_enabled
      expect(ch_tag[17]).to eq("false")  # default post_only
    end
  end

  describe "build_metadata_tags" do
    it "includes server_type and age_restricted" do
      server.update!(server_type: "gaming", age_restricted: true)

      job = NostrServerPublishJob.new
      job.instance_variable_set(:@server, server.reload)
      job.instance_variable_set(:@user, owner)
      tags = job.send(:build_metadata_tags)

      server_type_tag = tags.find { |t| t[0] == "server_type" }
      age_restricted_tag = tags.find { |t| t[0] == "age_restricted" }

      expect(server_type_tag[1]).to eq("gaming")
      expect(age_restricted_tag[1]).to eq("true")
    end

    it "includes afk_channel settings" do
      afk_channel = create(:channel, server: server, channel_type: :voice, name: "afk")
      server.update!(afk_channel: afk_channel, afk_timeout: 15, afk_action: "disconnect")

      job = NostrServerPublishJob.new
      job.instance_variable_set(:@server, server.reload)
      job.instance_variable_set(:@user, owner)
      tags = job.send(:build_metadata_tags)

      afk_tag = tags.find { |t| t[0] == "afk_channel" }
      timeout_tag = tags.find { |t| t[0] == "afk_timeout" }
      action_tag = tags.find { |t| t[0] == "afk_action" }

      expect(afk_tag[1]).to eq(afk_channel.public_id)
      expect(timeout_tag[1]).to eq("15")
      expect(action_tag[1]).to eq("disconnect")
    end

    it "includes default afk values when not configured" do
      job = NostrServerPublishJob.new
      job.instance_variable_set(:@server, server.reload)
      job.instance_variable_set(:@user, owner)
      tags = job.send(:build_metadata_tags)

      timeout_tag = tags.find { |t| t[0] == "afk_timeout" }
      action_tag = tags.find { |t| t[0] == "afk_action" }

      expect(timeout_tag[1]).to eq("5")
      expect(action_tag[1]).to eq("move")
    end
  end
end
