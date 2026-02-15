require 'rails_helper'

RSpec.describe "Settings", type: :request do
  include NostrTestHelpers

  describe "POST /settings/export_encrypted_key" do
    let(:user) do
      user = create(:user, :confirmed, password: "password123")
      # Give the user a real nostr keypair
      allow(user).to receive(:nostr_private_key).and_return(test_private_key)
      user
    end

    before do
      sign_in user
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
end
