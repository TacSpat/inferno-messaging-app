When("I try to sign up") do
  visit new_user_registration_path
end

Then("I should be redirected to the login page") do
  expect(page).to have_current_path(new_user_session_path)
end

Then("I should see the registration form") do
  has_form = page.has_field?("user_email") || page.has_field?("Email") || page.has_css?("form")
  expect(has_form).to be true
end
