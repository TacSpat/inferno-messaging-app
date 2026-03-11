require 'rails_helper'

RSpec.describe "Settings", type: :request do
  include NostrTestHelpers

  let(:user) { create(:user, :confirmed) }

  before do
    sign_in user
    allow(ConversationChannel).to receive(:broadcast_to) if defined?(ConversationChannel)
  end

  describe "POST /settings/export_encrypted_key" do
    let(:user) do
      user = create(:user, :confirmed, password: "password123")
      allow(user).to receive(:nostr_private_key).and_return(test_private_key)
      user
    end

    before do
      allow_any_instance_of(SettingsController).to receive(:current_user).and_return(user)
    end

    it "returns ncryptsec with valid passwords" do
      post export_encrypted_key_path, params: {
        password: "password123",
        backup_password: "strongbackup123"
      }

      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["ncryptsec"]).to start_with("ncryptsec1")
    end

    it "rejects wrong account password" do
      post export_encrypted_key_path, params: {
        password: "wrong_password",
        backup_password: "strongbackup123"
      }

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("Incorrect password")
    end

    it "rejects short backup password" do
      post export_encrypted_key_path, params: {
        password: "password123",
        backup_password: "short"
      }

      expect(response).to have_http_status(:unprocessable_entity)
      json = JSON.parse(response.body)
      expect(json["error"]).to include("at least 8 characters")
    end

    it "rejects blank backup password" do
      post export_encrypted_key_path, params: {
        password: "password123",
        backup_password: ""
      }

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "PATCH /settings/notifications" do
    it "updates notification preferences" do
      patch user_settings_notifications_path, params: {
        desktop_mentions: "1",
        desktop_dm_messages: "1",
        desktop_friend_requests: "0",
        desktop_updates: "0"
      }

      expect(response).to redirect_to(user_settings_notifications_path)
      user.reload
      expect(user.notification_preferences["desktop_mentions"]).to be true
      expect(user.notification_preferences["desktop_dm_messages"]).to be true
      expect(user.notification_preferences["desktop_friend_requests"]).to be false
      expect(user.notification_preferences["desktop_updates"]).to be false
    end
  end

  describe "GET /settings/storage" do
    it "returns 200" do
      get user_settings_storage_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /settings/storage" do
    it "updates storage settings" do
      patch user_settings_storage_path, params: {
        max_cache_size_mb: "200",
        backfill_days: "14",
        backfill_enabled: "1",
        pruning_strategy: "time_based",
        message_retention_days: "90",
        attachment_retention_days: "30",
        max_db_size_mb: "100",
        keep_pinned_messages: "1",
        prune_channel_messages: "1",
        prune_dm_messages: "0"
      }

      expect(response).to redirect_to(user_settings_storage_path)
      config = LocalConfig.current.reload
      expect(config.max_cache_size_mb).to eq(200)
      expect(config.backfill_days).to eq(14)
      expect(config.pruning_strategy).to eq("time_based")
      expect(config.message_retention_days).to eq(90)
    end
  end

  describe "POST /settings/clear_cache" do
    it "redirects with notice" do
      post user_settings_clear_cache_path
      expect(response).to redirect_to(user_settings_storage_path)
      expect(flash[:notice]).to include("Cleared")
    end
  end

  describe "GET /settings/safety" do
    it "returns 200" do
      get user_settings_safety_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH /settings/safety" do
    it "updates safety protection level" do
      patch user_settings_safety_path, params: { safety_protection_level: "relaxed" }

      expect(response).to redirect_to(user_settings_safety_path)
      expect(LocalConfig.current.reload.safety_protection_level).to eq("relaxed")
    end
  end

  describe "POST /settings/hide_message/:id" do
    let(:message) { create(:message) }

    it "hides the message" do
      allow(LocalConfig.current).to receive(:safety_image_hash_enabled).and_return(false)

      post user_settings_hide_message_path(message.public_id), params: { reason: "test" }

      expect(response).to redirect_to(user_settings_safety_path)
      expect(message.reload.hidden_at).to be_present
    end
  end

  describe "POST /settings/unhide_message/:id" do
    let(:message) { create(:message) }

    before do
      allow(LocalConfig.current).to receive(:safety_image_hash_enabled).and_return(false)
      message.hide!(user, reason: "test")
    end

    it "unhides the message" do
      post user_settings_unhide_message_path(message.public_id)

      expect(response).to redirect_to(user_settings_safety_path)
      expect(message.reload.hidden_at).to be_nil
    end
  end

  describe "GET /settings/authority_report/:id" do
    let(:message) { create(:message) }

    context "when message is hidden" do
      before do
        allow(LocalConfig.current).to receive(:safety_image_hash_enabled).and_return(false)
        message.hide!(user, reason: "test")
      end

      it "returns 200" do
        get user_settings_authority_report_path(message.public_id)
        expect(response).to have_http_status(:ok)
      end
    end

    context "when message is not hidden" do
      it "redirects" do
        get user_settings_authority_report_path(message.public_id)
        expect(response).to redirect_to(user_settings_safety_path)
      end
    end
  end

  describe "POST /settings/generate_authority_report/:id" do
    let(:message) { create(:message) }

    before do
      allow(LocalConfig.current).to receive(:safety_image_hash_enabled).and_return(false)
      message.hide!(user, reason: "test")
    end

    it "generates a text report" do
      post user_settings_generate_authority_report_path(message.public_id), params: { category: "threats" }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/plain")
      expect(response.headers["Content-Disposition"]).to include("attachment")
      expect(response.body).to include("REPORT FOR LAW ENFORCEMENT")
    end
  end

  describe "POST /settings/dismiss_hint" do
    it "adds hint key to seen_hints" do
      post dismiss_hint_settings_path, params: { hint_key: "server_rail" }

      expect(response).to have_http_status(:ok)
      expect(user.reload.seen_hints).to include("server_rail")
    end
  end

  describe "POST /settings/reset_hints" do
    before do
      user.update_column(:seen_hints, [ "server_rail", "add_server" ])
      user.update_column(:tutorial_completed_at, Time.current)
    end

    it "clears seen_hints and tutorial_completed_at" do
      post reset_hints_settings_path

      expect(response).to redirect_to(root_path)
      user.reload
      expect(user.seen_hints).to be_empty
      expect(user.tutorial_completed_at).to be_nil
    end
  end

  describe "POST /settings/dismiss_all_hints" do
    it "marks all hints as seen" do
      post dismiss_all_hints_settings_path

      expect(response).to have_http_status(:ok)
      user.reload
      expect(user.seen_hints).to include("server_rail", "add_server", "channel_list")
      expect(user.tutorial_completed_at).to be_present
    end
  end

  describe "POST /settings/run_prune" do
    it "enqueues PruneMessagesJob" do
      post user_settings_run_prune_path

      expect(response).to redirect_to(user_settings_storage_path)
      expect(PruneMessagesJob).to have_been_enqueued
    end
  end
end
