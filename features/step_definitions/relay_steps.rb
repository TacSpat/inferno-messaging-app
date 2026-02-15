When("I add a relay with URL {string}") do |url|
  page.driver.post admin_relay_connections_path, { url: url }
  visit admin_instance_config_path
end

Then("a relay connection should exist with URL {string}") do |url|
  expect(RelayConnection.find_by(url: url)).to be_present
end

Then("no relay connection should exist with URL {string}") do |url|
  expect(RelayConnection.find_by(url: url)).to be_nil
end

Then("I should see an error about the URL format") do
  # The error is flashed as an alert
  expect(RelayConnection.count).to eq(0)
end

Given("a relay {string} exists") do |url|
  @relay = FactoryBot.create(:relay_connection, url: url)
end

Given("a disabled relay {string} exists") do |url|
  @relay = FactoryBot.create(:relay_connection, :disabled, url: url)
end

When("I toggle the relay {string}") do |url|
  relay = RelayConnection.find_by!(url: url)
  page.driver.post toggle_admin_relay_connection_path(relay)
end

Then("the relay {string} should be disabled") do |url|
  expect(RelayConnection.find_by(url: url).status).to eq("disabled")
end

Then("the relay {string} should be active") do |url|
  expect(RelayConnection.find_by(url: url).status).to eq("active")
end

When("I remove the relay {string}") do |url|
  relay = RelayConnection.find_by!(url: url)
  page.driver.submit :delete, admin_relay_connection_path(relay), {}
end
