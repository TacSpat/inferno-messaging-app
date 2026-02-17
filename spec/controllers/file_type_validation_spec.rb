require 'rails_helper'

RSpec.describe "File type validation", type: :request do
  let(:user) { create(:user, :confirmed) }
  let(:server) { create(:server, owner: user) }
  let(:channel) { server.channels.first }

  before { sign_in user }

  describe "MessagesController" do
    it "rejects disallowed file types" do
      exe_file = fixture_file_upload(
        Rails.root.join("spec/fixtures/files/test.txt"),
        "application/x-msdownload"
      )

      post channel_messages_path(channel), params: {
        message: { content: "test", files: [ exe_file ] }
      }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body["error"]).to include("not allowed")
    end

    it "accepts allowed file types" do
      png_file = fixture_file_upload(
        Rails.root.join("spec/fixtures/files/test.txt"),
        "image/png"
      )

      post channel_messages_path(channel), params: {
        message: { content: "test", files: [ png_file ] }
      }

      expect(response).not_to have_http_status(:unprocessable_entity)
    end

    it "allows messages without files" do
      post channel_messages_path(channel), params: {
        message: { content: "hello" }
      }

      expect(response).not_to have_http_status(:unprocessable_entity)
    end
  end
end
