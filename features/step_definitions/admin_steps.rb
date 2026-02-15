Given("the instance has emergency lockdown enabled") do
  InstanceConfig.current.emergency_lockdown!
end

Given("the instance has local signups blocked") do
  InstanceConfig.current.update!(lockdown_local_signups: true)
end

Given("the domain {string} is blocklisted") do |domain|
  admin = @current_user || FactoryBot.create(:user, :confirmed, :admin)
  InstanceBlocklist.create!(domain: domain, blocked_by: admin, blocked_at: Time.current)
end

Given("federation mode is {string}") do |mode|
  InstanceConfig.current.update!(federation_mode: mode)
end

When("I activate emergency lockdown") do
  page.driver.post emergency_lockdown_admin_instance_config_path
  visit admin_instance_config_path
end

When("I lift the lockdown") do
  page.driver.post lift_lockdown_admin_instance_config_path
  visit admin_instance_config_path
end

When("I update instance settings with {string} enabled") do |setting|
  page.driver.submit :patch, admin_instance_config_path, {
    instance_config: { setting => true }
  }
end

When("I try to access the admin instance config") do
  visit admin_instance_config_path
end

Then("all lockdown flags should be enabled") do
  config = InstanceConfig.current.reload
  expect(config.lockdown_enabled).to be true
  expect(config.lockdown_remote_auth).to be true
  expect(config.lockdown_remote_joins).to be true
  expect(config.lockdown_local_signups).to be true
  expect(config.lockdown_invite_creation).to be true
end

Then("all lockdown flags should be disabled") do
  config = InstanceConfig.current.reload
  expect(config.lockdown_enabled).to be false
  expect(config.lockdown_remote_auth).to be false
end

Then("remote auth should be blocked") do
  expect(InstanceConfig.current.reload.remote_auth_blocked?).to be true
end
