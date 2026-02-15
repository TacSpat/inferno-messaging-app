Given("I am in the general channel of my server") do
  @channel = @server.channels.find_by(name: "general")
end

When("I send a message with content {string}") do |content|
  page.driver.post channel_messages_path(@channel), {
    message: { content: content }
  }
end

Then("a message {string} should exist in the channel") do |content|
  expect(@channel.messages.exists?(content: content)).to be true
end

When("I send a message with an image attachment") do
  file = Rack::Test::UploadedFile.new(
    Rails.root.join("spec/fixtures/files/test_image.png"), "image/png"
  )
  page.driver.post channel_messages_path(@channel), {
    message: { content: "image post", files: [file] }
  }
end

When("I send a message with a video attachment") do
  file = Rack::Test::UploadedFile.new(
    Rails.root.join("spec/fixtures/files/test_video.mp4"), "video/mp4"
  )
  page.driver.post channel_messages_path(@channel), {
    message: { content: "video post", files: [file] }
  }
end

When("I send a message with a gif attachment") do
  file = Rack::Test::UploadedFile.new(
    Rails.root.join("spec/fixtures/files/test_image.gif"), "image/gif"
  )
  page.driver.post channel_messages_path(@channel), {
    message: { content: "gif post", files: [file] }
  }
end

Then("the latest message should have a file attached") do
  message = @channel.messages.order(created_at: :desc).first
  expect(message.files).to be_attached
end

Given("a message {string} exists in the channel") do |content|
  @message = @channel.messages.create!(content: content, user: @current_user)
end

When("I react to the message with {string}") do |emoji|
  page.driver.post toggle_reaction_channel_message_path(@channel, @message), {
    emoji: emoji
  }
end

Then("the message should have a {string} reaction from me") do |emoji|
  expect(@message.reactions.exists?(user: @current_user, emoji: emoji)).to be true
end
