require 'rails_helper'

RSpec.describe "Calls", type: :request do
  let(:user) { create(:user, :confirmed) }
  let(:other) { create(:user, :confirmed) }
  let(:conversation) { create(:conversation, kind: :direct) }

  before do
    sign_in user
    conversation.conversation_participants.create!(user: user, accepted: true)
    conversation.conversation_participants.create!(user: other, accepted: true)
    allow(ConversationChannel).to receive(:broadcast_to)
  end

  def configure_livekit(target_user)
    target_user.update!(
      livekit_url: "wss://livekit.example.com",
      livekit_api_key: "test_key",
      livekit_api_secret: "test_secret_that_is_long_enough"
    )
  end

  describe "POST /conversations/:conversation_id/calls" do
    context "with LiveKit configured" do
      before { configure_livekit(user) }

      it "creates a call and returns JSON" do
        post conversation_calls_path(conversation.public_id)

        expect(response).to have_http_status(:ok)
        json = JSON.parse(response.body)
        expect(json["call_id"]).to be_present
        expect(json["token"]).to be_present
        expect(json["room_name"]).to be_present
        expect(CallRingTimeoutJob).to have_been_enqueued
      end
    end

    context "without LiveKit configured" do
      it "returns 422 with error" do
        post conversation_calls_path(conversation.public_id)

        expect(response).to have_http_status(:unprocessable_entity)
        json = JSON.parse(response.body)
        expect(json["error"]).to include("LiveKit")
      end
    end
  end

  describe "POST /conversations/:conversation_id/calls/:id/accept" do
    let(:call) do
      configure_livekit(user)
      conversation.calls.create!(initiated_by: other, status: "ringing")
    end

    it "accepts the call and returns token" do
      post accept_conversation_call_path(conversation.public_id, call.public_id)

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["token"]).to be_present
      expect(call.reload.status).to eq("active")
    end
  end

  describe "POST /conversations/:conversation_id/calls/:id/decline" do
    let(:call) do
      conversation.calls.create!(initiated_by: other, status: "ringing")
    end

    it "declines the call" do
      post decline_conversation_call_path(conversation.public_id, call.public_id)

      expect(response).to have_http_status(:ok)
      expect(call.reload.status).to eq("declined")
    end
  end

  describe "POST /conversations/:conversation_id/calls/:id/join" do
    let(:call) do
      configure_livekit(user)
      c = conversation.calls.create!(initiated_by: other, status: "active", started_at: Time.current)
      c.call_participants.create!(user: other, joined_at: Time.current)
      c
    end

    it "creates a participant and returns token" do
      post join_conversation_call_path(conversation.public_id, call.public_id)

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["token"]).to be_present
      expect(call.call_participants.where(user: user)).to exist
    end
  end

  describe "POST /conversations/:conversation_id/calls/:id/hangup" do
    let(:call) do
      c = conversation.calls.create!(initiated_by: user, status: "active", started_at: Time.current)
      c.call_participants.create!(user: user, joined_at: Time.current)
      c
    end

    it "sets left_at and ends call when last participant leaves" do
      post hangup_conversation_call_path(conversation.public_id, call.public_id)

      expect(response).to have_http_status(:ok)
      expect(call.call_participants.find_by(user: user).left_at).to be_present
      expect(call.reload.status).to eq("ended")
    end
  end

  describe "non-participant access" do
    let(:outsider) { create(:user, :confirmed) }

    it "returns forbidden" do
      sign_in outsider
      post conversation_calls_path(conversation.public_id)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
