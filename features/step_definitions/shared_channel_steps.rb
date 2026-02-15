Given("my server has a channel named {string}") do |name|
  @channel = @server.channels.find_by(name: name) || @server.channels.first
end

Given("my server has a shared channel named {string}") do |name|
  @channel = @server.channels.first
  @channel.enable_sharing!(relay_url: "wss://relay.example.com")
end

When("I bridge the channel to relay {string}") do |relay_url|
  page.driver.post bridge_server_channel_path(@server, @channel), {
    relay_url: relay_url
  }
end

When("I unbridge the channel") do
  page.driver.submit :delete, unbridge_server_channel_path(@server, @channel), {}
end

Then("the channel should be shared") do
  expect(@channel.reload.shared?).to be true
end

Then("the channel should not be shared") do
  expect(@channel.reload.shared?).to be false
end

Then("the channel should have a nostr group ID") do
  expect(@channel.reload.nostr_group_id).to be_present
end
