require "rails_helper"

RSpec.describe "Messages", type: :request do
  let(:user) { create(:user, :confirmed) }
  let!(:server) { create(:server, owner: user) }
  let(:channel) { server.channels.find_by(name: "general") }

  before { sign_in user }

  describe "POST /channels/:channel_id/messages" do
    it "creates a message with text content" do
      expect {
        post channel_messages_path(channel.public_id), params: { message: { content: "Hello world" } }
      }.to change(channel.messages, :count).by(1)

      expect(channel.messages.last.content).to eq("Hello world")
      expect(response).to redirect_to(server_channel_path(server, channel))
    end

    it "attaches an image file" do
      image = fixture_file_upload("test_image.png", "image/png")

      expect {
        post channel_messages_path(channel.public_id), params: { message: { content: "check this out", files: [ image ] } }
      }.to change(channel.messages, :count).by(1)

      expect(channel.messages.last.files).to be_attached
    end

    it "attaches a video file" do
      video = fixture_file_upload("test_video.mp4", "video/mp4")

      expect {
        post channel_messages_path(channel.public_id), params: { message: { content: "video here", files: [ video ] } }
      }.to change(channel.messages, :count).by(1)

      expect(channel.messages.last.files).to be_attached
    end

    it "attaches a gif file" do
      gif = fixture_file_upload("test_image.gif", "image/gif")

      expect {
        post channel_messages_path(channel.public_id), params: { message: { content: "funny gif", files: [ gif ] } }
      }.to change(channel.messages, :count).by(1)

      expect(channel.messages.last.files).to be_attached
    end

    it "rejects message without content or files" do
      expect {
        post channel_messages_path(channel.public_id), params: { message: { content: "" } }
      }.not_to change(Message, :count)
    end

    it "rejects content over 4000 characters" do
      long_content = "a" * 4001

      expect {
        post channel_messages_path(channel.public_id), params: { message: { content: long_content } }
      }.not_to change(Message, :count)
    end

    it "requires authentication" do
      sign_out user
      post channel_messages_path(channel.public_id), params: { message: { content: "hello" } }
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
