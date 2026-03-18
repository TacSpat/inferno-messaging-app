Given("a server owner exists with a server") do
  @owner = FactoryBot.create(:user, :confirmed, password: "password123")
  @server = FactoryBot.create(:server, owner: @owner)
end

Given("my server has a nostr group ID") do
  @server.update!(nostr_group_id: "test-#{@server.public_id}") unless @server.nostr_group_id.present?
end

Given("my server has a voice channel {string} with bitrate {int} and user limit {int}") do |name, bitrate, limit|
  @voice_channel = @server.channels.create!(
    name: name, channel_type: :voice,
    voice_bitrate: bitrate, voice_user_limit: limit, video_enabled: true
  )
end

Given("my server has a voice channel {string}") do |name|
  @channels ||= {}
  @channels[name] = @server.channels.create!(name: name, channel_type: :voice)
end

Given("my server has a text channel {string}") do |name|
  @channels ||= {}
  @channels[name] = @server.channels.create!(name: name, channel_type: :text)
end

Given("my server has a voice channel {string} nested under {string}") do |child_name, parent_name|
  @channels ||= {}
  parent = @channels[parent_name] || @server.channels.find_by!(name: parent_name)
  @channels[child_name] = @server.channels.create!(
    name: child_name, channel_type: :voice, parent_channel: parent
  )
end

Given("{string} is linked to sidechat {string}") do |voice_name, text_name|
  voice = @channels[voice_name] || @server.channels.find_by!(name: voice_name)
  text = @channels[text_name] || @server.channels.find_by!(name: text_name)
  voice.update_columns(sidechat_channel_id: text.id)
end

Given("my server has a post-only channel {string}") do |name|
  @channels ||= {}
  @channels[name] = @server.channels.create!(name: name, channel_type: :text, post_only: true)
end

Given("the server AFK channel is {string} with timeout {int} and action {string}") do |name, timeout, action|
  ch = @channels[name] || @server.channels.find_by!(name: name)
  @server.update!(afk_channel: ch, afk_timeout: timeout, afk_action: action)
end

Given("the server type is {string} and age restricted") do |type|
  @server.update!(server_type: type, age_restricted: true)
end

Given("the server was last synced {int} minutes ago") do |minutes|
  @server.update_column(:last_synced_at, minutes.minutes.ago)
end

Given("the server was last synced {int} hours ago") do |hours|
  @server.update_column(:last_synced_at, hours.hours.ago)
end

# --- Publishing ---

When("the structure is published to relays") do
  # Stub BlossomClientService at class level (no RSpec allow needed)
  BlossomClientService.define_singleton_method(:upload_attachment) { |*_| "https://blossom.test/img.png" }

  job = NostrServerPublishJob.new
  job.instance_variable_set(:@server, @server.reload)
  job.instance_variable_set(:@user, @owner)
  @published_structure_tags = job.send(:build_structure_tags)
end

When("the metadata is published to relays") do
  BlossomClientService.define_singleton_method(:upload_attachment) { |*_| "https://blossom.test/img.png" }

  job = NostrServerPublishJob.new
  job.instance_variable_set(:@server, @server.reload)
  job.instance_variable_set(:@user, @owner)
  @published_metadata_tags = job.send(:build_metadata_tags)
end

# --- Structure assertions ---

Then("the published event should include voice_bitrate {string}") do |value|
  ch_tag = @published_structure_tags.find { |t| t[0] == "ch" && t[1] == @voice_channel.public_id }
  expect(ch_tag[14]).to eq(value)
end

Then("the published event should include voice_user_limit {string}") do |value|
  ch_tag = @published_structure_tags.find { |t| t[0] == "ch" && t[1] == @voice_channel.public_id }
  expect(ch_tag[15]).to eq(value)
end

Then("the published event should reference {string} as parent of {string}") do |parent_name, child_name|
  parent = @channels[parent_name]
  child = @channels[child_name]
  ch_tag = @published_structure_tags.find { |t| t[0] == "ch" && t[1] == child.public_id }
  expect(ch_tag[13]).to eq(parent.public_id)
end

Then("the published event should reference {string} as sidechat of {string}") do |text_name, voice_name|
  text = @channels[text_name]
  voice = @channels[voice_name]
  ch_tag = @published_structure_tags.find { |t| t[0] == "ch" && t[1] == voice.public_id }
  expect(ch_tag[12]).to eq(text.public_id)
end

Then("the published event should include post_only {string} for {string}") do |value, name|
  ch = @channels[name] || @server.channels.find_by!(name: name)
  ch_tag = @published_structure_tags.find { |t| t[0] == "ch" && t[1] == ch.public_id }
  expect(ch_tag[17]).to eq(value)
end

# --- Metadata assertions ---

Then("the published metadata should include afk_channel {string}") do |name|
  ch = @channels[name] || @server.channels.find_by!(name: name)
  tag = @published_metadata_tags.find { |t| t[0] == "afk_channel" }
  expect(tag[1]).to eq(ch.public_id)
end

Then("the published metadata should include afk_timeout {string}") do |value|
  tag = @published_metadata_tags.find { |t| t[0] == "afk_timeout" }
  expect(tag[1]).to eq(value)
end

Then("the published metadata should include afk_action {string}") do |value|
  tag = @published_metadata_tags.find { |t| t[0] == "afk_action" }
  expect(tag[1]).to eq(value)
end

Then("the published metadata should include server_type {string}") do |value|
  tag = @published_metadata_tags.find { |t| t[0] == "server_type" }
  expect(tag[1]).to eq(value)
end

Then("the published metadata should include age_restricted {string}") do |value|
  tag = @published_metadata_tags.find { |t| t[0] == "age_restricted" }
  expect(tag[1]).to eq(value)
end

# --- Receiving structure events ---

When("a remote structure event is received with nested channels") do
  gid = @server.nostr_group_id
  tags = [
    ["d", "inferno-struct-#{gid}"],
    ["server", gid],
    ["ch", "vc-parent", "parent-room", "voice", "0", "", "", "false", "", "{}", "false", "", "", "", "64000", "0", "false", "false"],
    ["ch", "vc-child", "child-room", "voice", "1", "", "", "false", "", "{}", "false", "", "", "vc-parent", "64000", "0", "false", "false"],
    ["ch", "tc-sidechat", "text-chat", "text", "2", "", "", "false", "", "{}", "false", "", "", "", "64000", "0", "false", "false"],
    ["ch", "vc-linked", "linked-voice", "voice", "3", "", "", "false", "", "{}", "false", "", "tc-sidechat", "", "128000", "10", "true", "false"]
  ]

  event = {
    "id" => SecureRandom.hex(32),
    "pubkey" => SecureRandom.hex(32),
    "kind" => 31751,
    "content" => "",
    "tags" => tags,
    "created_at" => Time.current.to_i
  }

  # Stub auth at class level
  NostrServerAuth.define_singleton_method(:authorized_for_event?) { |*_| true }
  Thread.current[:nostr_skip_auth] = true
  rsm = RelaySubscriptionManager.instance
  rsm.send(:process_server_structure, event)
  Thread.current[:nostr_skip_auth] = nil
end

Then("the local channels should have correct parent references") do
  child = @server.channels.find_by(public_id: "vc-child")
  parent = @server.channels.find_by(public_id: "vc-parent")
  expect(child.parent_channel).to eq(parent)
end

Then("the local channels should have correct sidechat links") do
  linked = @server.channels.find_by(public_id: "vc-linked")
  sidechat = @server.channels.find_by(public_id: "tc-sidechat")
  expect(linked.sidechat_channel).to eq(sidechat)
  expect(linked.voice_bitrate).to eq(128000)
  expect(linked.voice_user_limit).to eq(10)
  expect(linked.video_enabled).to eq(true)
end

# --- Channel deletion ---

When("I delete the channel {string}") do |name|
  ch = @channels[name] || @server.channels.find_by!(name: name)
  ch.destroy
end

Then("{string} should still exist") do |name|
  expect(@server.channels.find_by(name: name)).to be_present
end

Then("{string} should have no parent channel") do |name|
  ch = @server.channels.find_by!(name: name)
  expect(ch.parent_channel_id).to be_nil
end

# --- Periodic sync ---

When("periodic sync runs") do
  @sync_ran = false

  # Replace the service class method temporarily
  original_new = NostrServerSyncService.method(:new)
  sync_tracker = @sync_ran  # capture
  test_context = self

  NostrServerSyncService.define_singleton_method(:new) do |*args|
    mock = Object.new
    mock.define_singleton_method(:sync_all) { test_context.instance_variable_set(:@sync_ran, true) }
    mock
  end

  @last_synced_before = @server.last_synced_at

  rsm = RelaySubscriptionManager.instance
  rsm.send(:run_periodic_sync)

  # Restore original
  NostrServerSyncService.define_singleton_method(:new, original_new)
end

Then("the server should not be re-synced") do
  expect(@sync_ran).to eq(false)
end

Then("the server should be synced") do
  expect(@sync_ran).to eq(true)
end

Then("the last_synced_at should be unchanged") do
  @server.reload
  if @last_synced_before
    expect(@server.last_synced_at.to_i).to eq(@last_synced_before.to_i)
  else
    expect(@server.last_synced_at).to be_nil
  end
end

Then("the last_synced_at should be updated") do
  @server.reload
  expect(@server.last_synced_at).to be > @last_synced_before
end
