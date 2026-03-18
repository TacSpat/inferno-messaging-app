require 'rails_helper'

RSpec.describe RelaySubscriptionManager, "server sync processing" do
  include NostrTestHelpers

  let(:owner) do
    user = create(:user, :confirmed, nostr_public_key: test_public_key)
    allow(user).to receive(:nostr_private_key).and_return(test_private_key)
    user
  end
  let(:server) { create(:server, owner: owner) }
  let(:remote_pubkey) { NostrTestHelpers::TEST_PUBLIC_KEY_2 }

  let(:rsm) { RelaySubscriptionManager.instance }

  before do
    stub_relay_service
    stub_action_cable
    allow(User).to receive(:owner).and_return(owner)
    allow(NostrServerAuth).to receive(:authorized_for_event?).and_return(true)
    allow(RemoteAssetCache).to receive(:cache).and_return(nil)
    # Allow self-echo processing (simulates bootstrap)
    Thread.current[:nostr_skip_auth] = true
  end

  after do
    Thread.current[:nostr_skip_auth] = nil
  end

  describe "#process_server_structure" do
    def build_structure_event(ch_tags: [], cat_tags: [])
      gid = server.nostr_group_id
      tags = [
        ["d", "inferno-struct-#{gid}"],
        ["server", gid]
      ] + cat_tags + ch_tags

      {
        "id" => SecureRandom.hex(32),
        "pubkey" => remote_pubkey,
        "kind" => 31751,
        "content" => "",
        "tags" => tags,
        "created_at" => Time.current.to_i
      }
    end

    def ch_tag(public_id:, name:, type: "text", position: "0", cat_id: "", topic: "",
               nsfw: "false", group_id: "", perms: "{}", encrypted: "false", pub_key: "",
               sidechat_id: "", parent_id: "",
               voice_bitrate: "64000", voice_user_limit: "0", video_enabled: "false", post_only: "false")
      ["ch", public_id, name, type, position, cat_id, topic, nsfw, group_id, perms,
       encrypted, pub_key, sidechat_id, parent_id, voice_bitrate, voice_user_limit, video_enabled, post_only]
    end

    it "creates channels with voice settings from relay event" do
      event = build_structure_event(ch_tags: [
        ch_tag(public_id: "ch1", name: "voice-room", type: "voice",
               voice_bitrate: "128000", voice_user_limit: "25", video_enabled: "true")
      ])

      rsm.send(:process_server_structure, event)

      ch = server.channels.find_by(public_id: "ch1")
      expect(ch).to be_present
      expect(ch.voice_bitrate).to eq(128000)
      expect(ch.voice_user_limit).to eq(25)
      expect(ch.video_enabled).to eq(true)
    end

    it "creates channels with post_only flag" do
      event = build_structure_event(ch_tags: [
        ch_tag(public_id: "ch1", name: "announcements", post_only: "true")
      ])

      rsm.send(:process_server_structure, event)

      ch = server.channels.find_by(public_id: "ch1")
      expect(ch.post_only).to eq(true)
    end

    it "links parent channels in the second pass" do
      event = build_structure_event(ch_tags: [
        ch_tag(public_id: "parent-vc", name: "parent", type: "voice"),
        ch_tag(public_id: "child-vc", name: "child", type: "voice", parent_id: "parent-vc")
      ])

      rsm.send(:process_server_structure, event)

      parent = server.channels.find_by(public_id: "parent-vc")
      child = server.channels.find_by(public_id: "child-vc")
      expect(child.parent_channel).to eq(parent)
    end

    it "links sidechat channels in the second pass" do
      event = build_structure_event(ch_tags: [
        ch_tag(public_id: "vc1", name: "voice", type: "voice", sidechat_id: "tc1"),
        ch_tag(public_id: "tc1", name: "text-chat")
      ])

      rsm.send(:process_server_structure, event)

      vc = server.channels.find_by(public_id: "vc1")
      tc = server.channels.find_by(public_id: "tc1")
      expect(vc.sidechat_channel).to eq(tc)
    end

    it "clears parent_channel when remote event removes it" do
      # Create an existing channel with a parent
      parent = create(:channel, server: server, channel_type: :voice, name: "parent")
      child = create(:channel, server: server, channel_type: :voice, name: "child", parent_channel: parent)

      # Send event with child having no parent_id
      event = build_structure_event(ch_tags: [
        ch_tag(public_id: parent.public_id, name: "parent", type: "voice"),
        ch_tag(public_id: child.public_id, name: "child", type: "voice", parent_id: "")
      ])

      rsm.send(:process_server_structure, event)

      child.reload
      expect(child.parent_channel_id).to be_nil
    end

    it "clears sidechat link when remote event removes it" do
      text = create(:channel, server: server, name: "text")
      voice = create(:channel, server: server, channel_type: :voice, name: "voice")
      voice.update_columns(sidechat_channel_id: text.id)

      event = build_structure_event(ch_tags: [
        ch_tag(public_id: voice.public_id, name: "voice", type: "voice", sidechat_id: ""),
        ch_tag(public_id: text.public_id, name: "text")
      ])

      rsm.send(:process_server_structure, event)

      voice.reload
      expect(voice.sidechat_channel_id).to be_nil
    end

    it "removes channels not in the event" do
      orphan = create(:channel, server: server, name: "orphan")
      kept = create(:channel, server: server, name: "kept")

      event = build_structure_event(ch_tags: [
        ch_tag(public_id: kept.public_id, name: "kept")
      ])

      rsm.send(:process_server_structure, event)

      expect(server.channels.exists?(id: orphan.id)).to eq(false)
      expect(server.channels.exists?(id: kept.id)).to eq(true)
    end

    it "syncs categories with correct positions" do
      event = build_structure_event(
        cat_tags: [
          ["cat", "cat1", "General", "0"],
          ["cat", "cat2", "Voice Channels", "1"]
        ],
        ch_tags: [
          ch_tag(public_id: "ch1", name: "general", cat_id: "cat1")
        ]
      )

      rsm.send(:process_server_structure, event)

      cat1 = server.categories.find_by(public_id: "cat1")
      cat2 = server.categories.find_by(public_id: "cat2")
      expect(cat1.name).to eq("General")
      expect(cat1.position).to eq(0)
      expect(cat2.name).to eq("Voice Channels")
      expect(cat2.position).to eq(1)

      ch = server.channels.find_by(public_id: "ch1")
      expect(ch.category).to eq(cat1)
    end

    it "handles voice settings with default values when tags are missing (backward compat)" do
      # Simulate an event from an older instance that doesn't include t[14]-t[17]
      short_tag = ["ch", "ch1", "general", "text", "0", "", "", "false", "", "{}", "false", "", "", ""]

      event = build_structure_event(ch_tags: [short_tag])

      rsm.send(:process_server_structure, event)

      ch = server.channels.find_by(public_id: "ch1")
      expect(ch).to be_present
      # Should keep defaults — not crash
      expect(ch.voice_bitrate).to eq(64000)
      expect(ch.video_enabled).to eq(false)
      expect(ch.post_only).to eq(false)
    end

    it "broadcasts sidebar_refresh after structure sync" do
      expect(ServerChannel).to receive(:broadcast_to).with(
        server, hash_including(type: "sidebar_refresh")
      )

      event = build_structure_event(ch_tags: [
        ch_tag(public_id: "ch1", name: "general")
      ])

      rsm.send(:process_server_structure, event)
    end
  end

  describe "#process_server_metadata" do
    def build_metadata_event(extra_tags: [])
      gid = server.nostr_group_id
      tags = [
        ["d", "inferno-#{gid}"],
        ["name", server.name],
        ["about", "Test server"],
        ["owner", owner.nostr_public_key],
        ["welcome_enabled", "true"],
        ["welcome_message", "Welcome!"],
        ["voice_enabled", "true"],
        ["discoverable", "false"]
      ] + extra_tags

      {
        "id" => SecureRandom.hex(32),
        "pubkey" => remote_pubkey,
        "kind" => 31750,
        "content" => "",
        "tags" => tags,
        "created_at" => Time.current.to_i
      }
    end

    it "syncs server_type and age_restricted" do
      event = build_metadata_event(extra_tags: [
        ["server_type", "gaming"],
        ["age_restricted", "true"]
      ])

      rsm.send(:process_server_metadata, event)

      server.reload
      expect(server.server_type).to eq("gaming")
      expect(server.age_restricted).to eq(true)
    end

    it "syncs afk channel settings" do
      afk_ch = create(:channel, server: server, channel_type: :voice, name: "afk")

      event = build_metadata_event(extra_tags: [
        ["afk_channel", afk_ch.public_id],
        ["afk_timeout", "15"],
        ["afk_action", "disconnect"]
      ])

      rsm.send(:process_server_metadata, event)

      server.reload
      expect(server.afk_channel).to eq(afk_ch)
      expect(server.afk_timeout).to eq(15)
      expect(server.afk_action).to eq("disconnect")
    end

    it "syncs welcome_channel_id from nostr_group_id" do
      welcome_ch = create(:channel, server: server, name: "welcome")

      event = build_metadata_event(extra_tags: [
        ["welcome_channel", welcome_ch.nostr_group_id]
      ])

      rsm.send(:process_server_metadata, event)

      server.reload
      expect(server.welcome_channel).to eq(welcome_ch)
    end

    it "handles missing optional tags gracefully without changing defaults" do
      server.update!(server_type: "community", age_restricted: false, afk_timeout: 5)
      event = build_metadata_event(extra_tags: [])

      rsm.send(:process_server_metadata, event)

      server.reload
      # Existing values should remain unchanged when tags are absent
      expect(server.server_type).to eq("community")
      expect(server.age_restricted).to eq(false)
      expect(server.afk_timeout).to eq(5)
      expect(server.afk_channel_id).to be_nil
    end

    it "broadcasts server_updated after metadata sync" do
      expect(ServerChannel).to receive(:broadcast_to).with(
        server, hash_including(type: "server_updated")
      )

      event = build_metadata_event
      rsm.send(:process_server_metadata, event)
    end
  end

  describe "#process_group_message spoiler sync" do
    before do
      # Ensure remote pubkey has a contact so ensure_remote_member can render
      Contact.create!(pubkey: remote_pubkey, display_name: "Remote User")
      # Stub view rendering that needs Warden (no request context in service tests)
      allow(ApplicationController).to receive(:render).and_return("<div>message</div>")
      allow(NostrProfileResolver).to receive(:resolve)
    end

    it "creates messages with spoiler flag from relay events" do
      channel = create(:channel, :shared, server: server)

      event = {
        "id" => SecureRandom.hex(32),
        "pubkey" => remote_pubkey,
        "kind" => 9,
        "content" => "Secret content",
        "tags" => [
          ["h", channel.nostr_group_id],
          ["spoiler"]
        ],
        "created_at" => Time.current.to_i
      }

      rsm.send(:process_group_message, event)

      msg = channel.messages.find_by(nostr_event_id: event["id"])
      expect(msg).to be_present
      expect(msg.spoiler).to eq(true)
    end

    it "creates messages without spoiler flag when tag is absent" do
      channel = create(:channel, :shared, server: server)

      event = {
        "id" => SecureRandom.hex(32),
        "pubkey" => remote_pubkey,
        "kind" => 9,
        "content" => "Normal message",
        "tags" => [["h", channel.nostr_group_id]],
        "created_at" => Time.current.to_i
      }

      rsm.send(:process_group_message, event)

      msg = channel.messages.find_by(nostr_event_id: event["id"])
      expect(msg).to be_present
      expect(msg.spoiler).to eq(false)
    end
  end
end
