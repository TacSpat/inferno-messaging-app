require 'rails_helper'

RSpec.describe SetupController, type: :request do
  include NostrTestHelpers

  before do
    stub_relay_service
    allow(NostrPublishJob).to receive(:perform_later)
    allow(MigrateIdentityJob).to receive(:perform_later)
  end

  describe "POST /setup (migrate mode)" do
    let(:private_key) { test_private_key }
    let(:public_key) { test_public_key }

    context "with avatar and banner URLs" do
      let(:avatar_path) { Rails.root.join("spec/fixtures/files/test_image.png") }

      before do
        # Set up RemoteAssetCache to return a valid path
        FileUtils.mkdir_p(Rails.root.join("public/cached_assets"))
        FileUtils.cp(avatar_path, Rails.root.join("public/cached_assets/test_avatar.png"))
        allow(RemoteAssetCache).to receive(:cache).with("https://example.com/avatar.png")
          .and_return("/cached_assets/test_avatar.png")
        allow(RemoteAssetCache).to receive(:cache).with("https://example.com/banner.jpg")
          .and_return(nil)  # Banner download fails
      end

      after do
        FileUtils.rm_f(Rails.root.join("public/cached_assets/test_avatar.png"))
      end

      it "attaches avatar from remote URL during migration" do
        post setup_path, params: {
          user: { username: "migrator", password: "password123", password_confirmation: "password123" },
          setup_mode: "migrate",
          migrate_private_key: private_key,
          fetched_display_name: "Migrator",
          fetched_bio: "Testing migration",
          fetched_avatar_url: "https://example.com/avatar.png",
          fetched_banner_url: "https://example.com/banner.jpg"
        }

        user = User.find_by(username: "migrator")
        expect(user).to be_present
        expect(user.avatar.attached?).to eq(true)
        expect(user.banner.attached?).to eq(false)  # Failed to download
      end

      it "continues migration even if media download fails" do
        allow(RemoteAssetCache).to receive(:cache).and_return(nil)

        post setup_path, params: {
          user: { username: "migrator2", password: "password123", password_confirmation: "password123" },
          setup_mode: "migrate",
          migrate_private_key: private_key,
          fetched_display_name: "Migrator2",
          fetched_avatar_url: "https://example.com/avatar.png"
        }

        user = User.find_by(username: "migrator2")
        expect(user).to be_present
        expect(user.avatar.attached?).to eq(false)
      end
    end
  end
end
