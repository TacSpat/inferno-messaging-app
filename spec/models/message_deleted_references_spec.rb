require 'rails_helper'

RSpec.describe Message, "deleted references", type: :model do
  describe "#render_content_html with deleted message links" do
    let(:server) { create(:server) }
    let(:channel) { server.channels.first || create(:channel, server: server) }
    let(:author) { create(:user, :confirmed) }

    it "shows placeholder for a deleted linked message" do
      msg = Message.create!(
        user: author,
        channel: channel,
        content: "/servers/#{server.public_id}/channels/#{channel.public_id}#message-nonexistent123",
        public_id: SecureRandom.alphanumeric(12)
      )

      html = msg.render_content_html
      expect(html).to include("no longer exists")
    end

    it "renders normally for an existing linked message" do
      linked = Message.create!(
        user: author,
        channel: channel,
        content: "Original message",
        public_id: SecureRandom.alphanumeric(12)
      )

      msg = Message.create!(
        user: author,
        channel: channel,
        content: "/servers/#{server.public_id}/channels/#{channel.public_id}#message-#{linked.public_id}",
        public_id: SecureRandom.alphanumeric(12)
      )

      html = msg.render_content_html
      expect(html).to include("Original message")
      expect(html).to include(author.username)
    end

    it "handles linked message with deleted user" do
      linked = Message.create!(
        user: author,
        channel: channel,
        content: "Message from deleted user",
        public_id: SecureRandom.alphanumeric(12)
      )

      msg = Message.create!(
        user: create(:user, :confirmed),
        channel: channel,
        content: "/servers/#{server.public_id}/channels/#{channel.public_id}#message-#{linked.public_id}",
        public_id: SecureRandom.alphanumeric(12)
      )

      # Simulate user deletion — the message row still exists but .user returns nil
      allow(linked).to receive(:user).and_return(nil)
      allow(Message).to receive(:find_by).with(public_id: linked.public_id).and_return(linked)

      html = msg.render_content_html
      expect(html).to include("Deleted User")
      expect(html).not_to include("no longer exists")
    end
  end

  describe "#render_custom_emojis with deleted user" do
    it "returns html unchanged when user is nil" do
      channel = create(:channel)
      msg = Message.new(
        channel: nil,
        user: nil,
        content: "Hello :test_emoji:"
      )

      html = msg.send(:render_custom_emojis, "<p>Hello :test_emoji:</p>")
      expect(html).to eq("<p>Hello :test_emoji:</p>")
    end
  end
end
