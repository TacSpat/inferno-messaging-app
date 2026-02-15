When("I visit the new server page") do
  visit new_server_path
end

When("I fill in {string} with {string}") do |field, value|
  fill_in field, with: value
end

When("I submit the server form with a blank name") do
  fill_in "Server Name", with: ""
  click_button "Create Server"
end

Then("I should be on the general channel of {string}") do |server_name|
  server = Server.find_by!(name: server_name)
  general = server.channels.find_by(name: "general")
  expect(page).to have_current_path(server_channel_path(server, general))
end

Then("the server {string} should have a general channel") do |server_name|
  server = Server.find_by!(name: server_name)
  expect(server.channels.exists?(name: "general")).to be true
end

Then("the server {string} should have default roles") do |server_name|
  server = Server.find_by!(name: server_name)
  expect(server.roles.pluck(:name)).to include("@everyone", "Admin", "Owner")
end

When("I visit the general channel of my server") do
  general = @server.channels.find_by(name: "general")
  visit server_channel_path(@server, general)
end

Then("I should see the channel name") do
  general = @server.channels.find_by(name: "general")
  expect(page).to have_content(general.name)
end

Then("I should see the message input area") do
  has_input = page.has_css?("textarea") || page.has_css?("input[type='text']")
  expect(has_input).to be true
end

When("I create a channel named {string} in my server") do |channel_name|
  page.driver.post server_channels_path(@server), {
    channel: { name: channel_name, channel_type: "text" }
  }
end

Then("I should be on the {string} channel page") do |channel_name|
  channel = Channel.find_by!(name: channel_name)
  expect(page.driver.response.location).to include(server_channel_path(channel.server, channel))
end

Given("a server {string} exists") do |name|
  other_owner = FactoryBot.create(:user, :confirmed)
  @other_server = FactoryBot.create(:server, name: name, owner: other_owner)
end

When("I try to visit the general channel of {string}") do |server_name|
  server = Server.find_by!(name: server_name)
  general = server.channels.find_by(name: "general")
  visit server_channel_path(server, general)
end

Then("I should see a server name error") do
  has_error = page.has_content?("can't be blank") || page.has_content?("Name")
  expect(has_error).to be true
end
