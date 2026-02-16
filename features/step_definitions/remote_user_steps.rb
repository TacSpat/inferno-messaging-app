Given("a remote user {string} from {string} is a member of my server") do |username, instance|
  remote_detail = FactoryBot.create(:remote_user,
    home_instance: instance,
    username: username,
    display_name: username
  )
  @remote_member = FactoryBot.create(:user, :remote,
    username: username,
    display_name: username,
    remote_user_detail: remote_detail
  )
  @server.server_memberships.create!(user: @remote_member)
end

Given("{string} has posted a message {string} in my server") do |username, content|
  user = User.find_by!(username: username)
  channel = @server.channels.find_by(name: "general")
  channel.messages.create!(user: user, content: content)
end

Then("I should see {string} in the member sidebar") do |text|
  expect(page).to have_content(text)
end

Then("I should not see any remote instance indicators") do
  expect(page).not_to have_css(".text-indigo-400\\/70")
end

When("I visit my server settings") do
  visit server_settings_overview_path(@server)
end

Given("I have a remote server {string} on {string}") do |name, instance_url|
  FactoryBot.create(:remote_server_reference,
    user: @current_user,
    remote_instance_url: instance_url,
    name: name
  )
end

When("I visit my account settings") do
  visit user_settings_account_path
end
