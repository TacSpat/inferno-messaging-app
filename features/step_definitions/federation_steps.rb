Given("I am signed in as a user with Nostr keys") do
  @current_user = create_and_sign_in_user
  # Users get Nostr keys automatically from HasNostrIdentity callback
  expect(@current_user.nostr_public_key).to be_present
end

Given("I am signed in as a user without Nostr keys") do
  @current_user = create_and_sign_in_user
  @current_user.update_columns(nostr_public_key: nil, nostr_encrypted_private_key: nil)
end

Given("there is an active relay connection to {string}") do |url|
  FactoryBot.create(:relay_connection, url: url, status: "active")
end

Given("federation is open") do
  InstanceConfig.current.update!(federation_mode: "open")
end

Given("federation is closed") do
  InstanceConfig.current.update!(federation_mode: "closed")
end

Given("the instance {string} is blocklisted") do |domain|
  admin = FactoryBot.create(:user, :confirmed, :admin)
  InstanceBlocklist.create!(domain: domain, blocked_by: admin, blocked_at: Time.current)
end

When("a remote user sends a valid server creation event for {string}") do |server_name|
  private_key = "5a26e4b9a456a8e8e1bf01a5e26ca7c25e5aea1f3b7e0c8d9f2a1b3c4d5e6f70"
  public_key = Nostr::Key.get_public_key(private_key)

  content = { name: server_name, description: "Federated", username: "remote_tester" }.to_json
  tags = [["d", "create_server"], ["relay", "wss://home.chat"]]
  created_at = Time.now.to_i

  serialized = [0, public_key, created_at, 30078, tags, content]
  id = Digest::SHA256.hexdigest(JSON.generate(serialized))

  message_bin = [id].pack("H*")
  private_key_bin = [private_key].pack("H*")
  signature = Schnorr.sign(message_bin, private_key_bin)
  sig_hex = signature.encode.unpack1("H*")

  event = {
    id: id, pubkey: public_key, created_at: created_at,
    kind: 30078, tags: tags, content: content, sig: sig_hex
  }

  page.driver.post "/federation/create_server",
    JSON.generate({ event: event }),
    { "CONTENT_TYPE" => "application/json" }
end

When("a remote user from {string} sends a server creation event for {string}") do |instance, server_name|
  private_key = "5a26e4b9a456a8e8e1bf01a5e26ca7c25e5aea1f3b7e0c8d9f2a1b3c4d5e6f70"
  public_key = Nostr::Key.get_public_key(private_key)

  content = { name: server_name, username: "evil_user" }.to_json
  tags = [["d", "create_server"], ["relay", "wss://#{instance}"]]
  created_at = Time.now.to_i

  serialized = [0, public_key, created_at, 30078, tags, content]
  id = Digest::SHA256.hexdigest(JSON.generate(serialized))

  message_bin = [id].pack("H*")
  private_key_bin = [private_key].pack("H*")
  signature = Schnorr.sign(message_bin, private_key_bin)
  sig_hex = signature.encode.unpack1("H*")

  event = {
    id: id, pubkey: public_key, created_at: created_at,
    kind: 30078, tags: tags, content: content, sig: sig_hex
  }

  page.driver.post "/federation/create_server",
    JSON.generate({ event: event }),
    { "CONTENT_TYPE" => "application/json" }
end

Then("the server {string} should exist") do |server_name|
  expect(Server.exists?(name: server_name)).to be true
end

Then("the server {string} should have an invite code") do |server_name|
  server = Server.find_by!(name: server_name)
  expect(server.invites.count).to be >= 1
end

Then("the server owner should be a remote user") do
  server = Server.last
  expect(server.owner.remote?).to be true
end

Then("the federation request should be rejected with {string}") do |message|
  response = page.driver.response
  expect(response.status).to be >= 400
  expect(response.body).to include(message)
end

Given("I have a remote server reference for {string} on {string}") do |name, instance|
  FactoryBot.create(:remote_server_reference,
    user: @current_user,
    name: name,
    remote_instance_url: "https://#{instance}",
    remote_server_id: "srv_#{SecureRandom.hex(4)}"
  )
end

When("I visit the home page") do
  visit root_path
end

Then("I should see {string} in the server rail") do |text|
  within("nav") do
    has_text = page.has_content?(text)
    has_title = page.has_css?("[title*='#{text}']")
    expect(has_text || has_title).to be true
  end
end

Then("I should not see {string}") do |text|
  expect(page).not_to have_content(text)
end
