require "rails_helper"

RSpec.describe "Reactions", type: :request do
  let(:user) { create(:user, :confirmed) }
  let!(:server) { create(:server, owner: user) }
  let(:channel) { server.channels.find_by(name: "general") }
  let!(:message) { channel.messages.create!(content: "React to me", user: user) }

  before { sign_in user }

  describe "POST toggle_reaction" do
    it "adds a reaction" do
      expect {
        post toggle_reaction_channel_message_path(channel.public_id, message.public_id), params: { emoji: "\u{1F44D}" }
      }.to change(Reaction, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(message.reactions.last.emoji).to eq("\u{1F44D}")
    end

    it "removes an existing reaction on second call" do
      message.reactions.create!(user: user, emoji: "\u{1F44D}")

      expect {
        post toggle_reaction_channel_message_path(channel.public_id, message.public_id), params: { emoji: "\u{1F44D}" }
      }.to change(Reaction, :count).by(-1)

      expect(response).to have_http_status(:ok)
    end

    it "returns bad_request without emoji param" do
      post toggle_reaction_channel_message_path(channel.public_id, message.public_id), params: { emoji: "" }
      expect(response).to have_http_status(:bad_request)
    end

    it "requires authentication" do
      sign_out user
      post toggle_reaction_channel_message_path(channel.public_id, message.public_id), params: { emoji: "\u{1F44D}" }
      expect(response).to redirect_to(new_user_session_path)
    end
  end
end
