Given("a confirmed user exists with email {string}") do |email|
  @test_user = FactoryBot.create(:user, :confirmed, email: email, password: "password123")
end

Given("an unconfirmed user exists with email {string}") do |email|
  @test_user = FactoryBot.create(:user, email: email, password: "password123", confirmed_at: nil)
end

When("I visit the login page") do
  visit new_user_session_path
end

When("I fill in my credentials with email {string} and password {string}") do |email, password|
  fill_in "Email", with: email
  fill_in "Password", with: password
end

When("I click {string}") do |button_text|
  click_button button_text
end

Then("I should be on the authenticated root page") do
  expect(page).to have_current_path(authenticated_root_path)
end

Then("I should be on the login page") do
  expect(page).to have_current_path(new_user_session_path)
end

Then("I should see a confirmation error") do
  expect(page).to have_content("confirm")
end
