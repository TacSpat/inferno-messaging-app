Then("I should see {string}") do |text|
  expect(page).to have_content(text)
end

Then("I should be redirected away") do
  expect([ root_path, new_user_session_path ]).to include(page.current_path)
end
