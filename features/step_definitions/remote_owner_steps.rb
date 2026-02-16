Given("I am signed in as a remote server owner from {string}") do |instance|
  remote_detail = FactoryBot.create(:remote_user,
    home_instance: instance,
    username: "remote_owner"
  )
  @current_user = FactoryBot.create(:user, :remote,
    username: "remote_owner",
    display_name: "Remote Owner",
    password: "password123",
    remote_user_detail: remote_detail
  )
  @server = FactoryBot.create(:server, owner: @current_user)
  sign_in_user(@current_user)
end

Given("a local user {string} is a member of my server") do |username|
  @local_member = FactoryBot.create(:user, :confirmed, username: username, display_name: username)
  @server.server_memberships.create!(user: @local_member, joined_at: Time.current)
end

Then("I should see my server name") do
  expect(page).to have_content(@server.name)
end

When("I update my server name to {string}") do |new_name|
  page.driver.submit :patch, server_settings_update_overview_path(@server), {
    server: { name: new_name }
  }
end

Then("the server should be named {string}") do |name|
  expect(@server.reload.name).to eq(name)
end

Then("the server should have a channel named {string}") do |channel_name|
  expect(@server.channels.exists?(name: channel_name)).to be true
end

When("I kick {string} from my server") do |username|
  member = User.find_by!(username: username)
  membership = @server.server_memberships.find_by!(user: member)
  page.driver.submit :delete, server_settings_kick_member_path(@server, membership), {}
end

Then("{string} should no longer be a member") do |username|
  member = User.find_by!(username: username)
  expect(@server.server_memberships.exists?(user: member)).to be false
end

When("I create an invite for my server") do
  @invite_count_before = @server.invites.count
  page.driver.post server_settings_create_invite_path(@server), {
    expires_in: "7d", max_uses: 10
  }
end

Then("my server should have a new invite") do
  expect(@server.invites.count).to be > @invite_count_before
end

When("I visit my server members settings") do
  visit server_settings_members_path(@server)
end
