require 'rails_helper'

RSpec.describe "Federation::FriendRequests", type: :request do
  let(:local_user) { create(:user, :confirmed, username: "alice") }
  let(:requesting_instance) { "remote.chat" }

  def build_signed_event(private_key_hex, public_key_hex, content_hash)
    content = content_hash.to_json
    tags = [ [ "d", "friend_request" ], [ "relay", "wss://remote.chat" ] ]
    created_at = Time.now.to_i

    serialized = [ 0, public_key_hex, created_at, 30078, tags, content ]
    id = Digest::SHA256.hexdigest(JSON.generate(serialized))

    message_bin = [ id ].pack("H*")
    private_key_bin = [ private_key_hex ].pack("H*")
    signature = Schnorr.sign(message_bin, private_key_bin)
    sig_hex = signature.encode.unpack1("H*")

    {
      id: id,
      pubkey: public_key_hex,
      created_at: created_at,
      kind: 30078,
      tags: tags,
      content: content,
      sig: sig_hex
    }
  end

  describe "POST /federation/users/lookup" do
    it "returns user profile by username and discriminator" do
      post federation_users_lookup_path, params: {
        username: local_user.username,
        discriminator: local_user.discriminator,
        requesting_instance: requesting_instance
      }, as: :json

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["pubkey"]).to eq(local_user.nostr_public_key)
      expect(body["username"]).to eq(local_user.username)
      expect(body["discriminator"]).to eq(local_user.discriminator)
      expect(body["profile_color"]).to eq(local_user.profile_color)
    end

    it "returns 404 when user not found" do
      post federation_users_lookup_path, params: {
        username: "nonexistent",
        discriminator: "9999",
        requesting_instance: requesting_instance
      }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "does not return remote users" do
      remote_detail = create(:remote_user, home_instance: "other.chat")
      create(:user, :confirmed, :remote, remote_user_detail: remote_detail,
             username: "remoteuser", nostr_public_key: remote_detail.nostr_public_key)

      post federation_users_lookup_path, params: {
        username: "remoteuser",
        discriminator: "0001",
        requesting_instance: requesting_instance
      }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    context "when federation is closed" do
      before { InstanceConfig.current.update!(federation_mode: "closed") }

      it "returns 403" do
        post federation_users_lookup_path, params: {
          username: local_user.username,
          discriminator: local_user.discriminator,
          requesting_instance: requesting_instance
        }, as: :json

        expect(response).to have_http_status(:forbidden)
      end
    end

    context "when requesting instance is blocked" do
      before do
        admin = create(:user, :confirmed, :admin)
        InstanceBlocklist.create!(domain: requesting_instance, blocked_by: admin, blocked_at: Time.current)
      end

      it "returns 403" do
        post federation_users_lookup_path, params: {
          username: local_user.username,
          discriminator: local_user.discriminator,
          requesting_instance: requesting_instance
        }, as: :json

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to include("restricted")
      end
    end
  end

  describe "POST /federation/friend_requests" do
    let(:sender_private_key) { Nostr::Key.generate_private_key }
    let(:sender_public_key) { Nostr::Key.get_public_key(sender_private_key) }
    let(:callback_token) { FederationCallbackTokenService.generate(from_pubkey: sender_public_key, to_pubkey: local_user.nostr_public_key) }

    let(:event_content) do
      {
        from_pubkey: sender_public_key,
        from_username: "bob",
        from_display_name: "Bob",
        from_discriminator: "1234",
        from_avatar_url: nil,
        from_profile_color: "#ff0000",
        to_username: local_user.username,
        to_discriminator: local_user.discriminator
      }
    end

    let(:signed_event) { build_signed_event(sender_private_key, sender_public_key, event_content) }

    it "creates a pending friendship from shadow sender to local target" do
      expect {
        post federation_friend_requests_path, params: {
          event: signed_event,
          from_instance_url: "http://remote.chat",
          callback_token: callback_token
        }, as: :json
      }.to change(Friendship, :count).by(1)
       .and change(RemoteUser, :count).by(1)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("sent")

      friendship = Friendship.last
      expect(friendship.status).to eq("pending")
      expect(friendship.friend).to eq(local_user)
      expect(friendship.user.remote?).to be true
      expect(friendship.federation_callback_token).to eq(callback_token)
    end

    it "returns 404 if target user not found" do
      event_content[:to_username] = "nonexistent"
      event_content[:to_discriminator] = "9999"
      event = build_signed_event(sender_private_key, sender_public_key, event_content)

      post federation_friend_requests_path, params: {
        event: event,
        from_instance_url: "http://remote.chat",
        callback_token: callback_token
      }, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it "returns 403 if target has blocked the sender" do
      # Create the shadow user first
      remote_user = RemoteUser.find_or_create_from_auth(
        public_key: sender_public_key,
        home_instance: "remote.chat",
        username: "bob"
      )
      shadow = remote_user.shadow_user
      Block.create!(blocker: local_user, blocked: shadow)

      post federation_friend_requests_path, params: {
        event: signed_event,
        from_instance_url: "http://remote.chat",
        callback_token: callback_token
      }, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to include("blocked")
    end

    it "returns 409 if friendship already exists" do
      remote_user = RemoteUser.find_or_create_from_auth(
        public_key: sender_public_key,
        home_instance: "remote.chat",
        username: "bob"
      )
      shadow = remote_user.shadow_user
      Friendship.create!(user: shadow, friend: local_user, status: :pending)

      post federation_friend_requests_path, params: {
        event: signed_event,
        from_instance_url: "http://remote.chat",
        callback_token: callback_token
      }, as: :json

      expect(response).to have_http_status(:conflict)
    end

    context "when sender's instance is blocked" do
      before do
        admin = create(:user, :confirmed, :admin)
        InstanceBlocklist.create!(domain: "remote.chat", blocked_by: admin, blocked_at: Time.current)
      end

      it "returns 403" do
        post federation_friend_requests_path, params: {
          event: signed_event,
          from_instance_url: "http://remote.chat",
          callback_token: callback_token
        }, as: :json

        expect(response).to have_http_status(:forbidden)
        expect(JSON.parse(response.body)["error"]).to include("restricted")
      end
    end
  end

  describe "POST /federation/friend_requests/respond" do
    let(:sender) { create(:user, :confirmed, username: "sender") }
    let(:remote_detail) { create(:remote_user, home_instance: "remote.chat") }
    let(:shadow_friend) { create(:user, :confirmed, :remote, remote_user_detail: remote_detail, username: "remotefriend", nostr_public_key: remote_detail.nostr_public_key) }
    let(:callback_token) { FederationCallbackTokenService.generate(from_pubkey: sender.nostr_public_key, to_pubkey: remote_detail.nostr_public_key) }
    let!(:friendship) { Friendship.create!(user: sender, friend: shadow_friend, status: :pending, federation_callback_token: callback_token) }

    it "accepts a friendship and creates conversation" do
      # Stub the outgoing push_conversation_reference call
      stub_request(:post, /remote\.chat.*push_reference/).to_return(status: 200, body: '{"status":"ok"}')

      post federation_friend_requests_respond_path, params: {
        callback_token: callback_token,
        status: "accepted",
        responder_pubkey: remote_detail.nostr_public_key,
        responder_username: "remotefriend",
        responder_display_name: "Remote Friend"
      }, as: :json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("ok")

      friendship.reload
      expect(friendship.status).to eq("accepted")

      # Reverse friendship should also exist
      reverse = Friendship.find_by(user: shadow_friend, friend: sender)
      expect(reverse).to be_present
      expect(reverse.status).to eq("accepted")

      # Conversation should be created
      conv = Conversation.joins(:conversation_participants)
        .where(conversation_participants: { user_id: sender.id })
        .joins("INNER JOIN conversation_participants cp2 ON cp2.conversation_id = conversations.id AND cp2.user_id = #{shadow_friend.id}")
        .first
      expect(conv).to be_present
    end

    it "declines a friendship" do
      post federation_friend_requests_respond_path, params: {
        callback_token: callback_token,
        status: "declined"
      }, as: :json

      expect(response).to have_http_status(:ok)
      friendship.reload
      expect(friendship.status).to eq("declined")
    end

    it "returns 401 with invalid token" do
      post federation_friend_requests_respond_path, params: {
        callback_token: "invalid_token",
        status: "accepted"
      }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 when no pending friendship found" do
      friendship.update!(status: :accepted)

      post federation_friend_requests_respond_path, params: {
        callback_token: callback_token,
        status: "accepted"
      }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /federation/conversations/push_reference" do
    it "creates a remote conversation reference for the user" do
      expect {
        post federation_conversations_push_reference_path, params: {
          requesting_instance: requesting_instance,
          for_pubkey: local_user.nostr_public_key,
          conversation_id: "abc123",
          instance_url: "http://remote.chat",
          other_username: "bob",
          other_display_name: "Bob",
          other_profile_color: "#ff0000"
        }, as: :json
      }.to change(RemoteConversationReference, :count).by(1)

      expect(response).to have_http_status(:ok)

      ref = RemoteConversationReference.last
      expect(ref.user).to eq(local_user)
      expect(ref.remote_conversation_id).to eq("abc123")
      expect(ref.remote_instance_url).to eq("http://remote.chat")
      expect(ref.other_username).to eq("bob")
    end

    it "returns 404 when user not found" do
      post federation_conversations_push_reference_path, params: {
        requesting_instance: requesting_instance,
        for_pubkey: "nonexistent_pubkey",
        conversation_id: "abc123",
        instance_url: "http://remote.chat"
      }, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
