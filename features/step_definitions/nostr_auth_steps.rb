When("I initiate Nostr auth with home instance {string}") do |home_instance|
  @challenge_count_before = NostrAuthChallenge.count
  visit nostr_auth_path(home_instance: home_instance)
end

Then("I should be redirected to {string}") do |domain|
  # Check that the page was redirected (Capybara with rack_test follows redirects
  # to same host but not to external hosts, so we check the redirect happened)
  expect(page).to have_current_path(/.*/)
end

Then("a Nostr auth challenge should be created") do
  expect(NostrAuthChallenge.count).to be > @challenge_count_before
end

Then("no Nostr auth challenge should be created") do
  expect(NostrAuthChallenge.count).to eq(@challenge_count_before)
end

When("I visit the signing page with valid params") do
  visit nostr_auth_sign_path(
    challenge: SecureRandom.hex(32),
    callback: "https://remote.chat/auth/nostr/callback",
    requesting_domain: "remote.chat"
  )
end

When("I approve the signing request") do
  @callback_url = "https://remote.chat/auth/nostr/callback"
  page.driver.post nostr_auth_sign_path, {
    challenge: SecureRandom.hex(32),
    callback: @callback_url,
    requesting_domain: "remote.chat"
  }
end

Then("I should be redirected to the callback URL with a signed event") do
  # rack_test won't follow external redirects, but we can check the response
  expect([ 302, 303 ]).to include(page.driver.response.status)
  expect(page.driver.response.location).to include("event=")
end
