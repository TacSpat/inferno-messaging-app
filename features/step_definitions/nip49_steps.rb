When("I export my encrypted key with password {string} and backup password {string}") do |password, backup_password|
  page.driver.post export_encrypted_key_path, {
    password: password,
    backup_password: backup_password
  }
  @last_response = page.driver.response
end

Then("I should receive an ncryptsec string") do
  json = JSON.parse(@last_response.body)
  expect(json["ncryptsec"]).to start_with("ncryptsec1")
end

Then("I should see an error about incorrect password") do
  json = JSON.parse(@last_response.body)
  expect(json["error"]).to include("Incorrect password")
end

Then("I should see an error about backup password length") do
  json = JSON.parse(@last_response.body)
  expect(json["error"]).to include("at least 8 characters")
end
