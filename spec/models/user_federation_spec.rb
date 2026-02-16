require 'rails_helper'

RSpec.describe User, "federation methods", type: :model do
  describe "#home_instance_domain" do
    it "returns nil for local users" do
      user = create(:user, :confirmed)
      expect(user.home_instance_domain).to be_nil
    end

    it "returns the home instance for remote users" do
      remote_detail = create(:remote_user, home_instance: "other.chat")
      user = create(:user, :confirmed, remote: true, remote_user_detail: remote_detail)
      expect(user.home_instance_domain).to eq("other.chat")
    end

    it "returns nil if remote user has no detail record" do
      user = build(:user, remote: true, remote_user_detail: nil)
      expect(user.home_instance_domain).to be_nil
    end
  end

  describe "remote_server_references association" do
    it "has many remote_server_references" do
      user = create(:user, :confirmed)
      ref = create(:remote_server_reference, user: user)
      expect(user.remote_server_references).to include(ref)
    end

    it "destroys references when user is destroyed" do
      user = create(:user, :confirmed)
      create(:remote_server_reference, user: user)
      expect { user.destroy }.to change(RemoteServerReference, :count).by(-1)
    end
  end

  describe "#nip05_identifier" do
    it "returns local identifier for local users" do
      user = create(:user, :confirmed, username: "alice")
      expect(user.nip05_identifier).to eq("alice@localhost")
    end

    it "returns home instance identifier for remote users" do
      user = create(:user, :remote, username: "bob")
      user.remote_user_detail.update!(username: "bob", home_instance: "home.chat")
      expect(user.nip05_identifier).to eq("bob@home.chat")
    end
  end

  describe "#effective_avatar_url" do
    it "returns nil for local user without avatar" do
      user = create(:user, :confirmed)
      expect(user.effective_avatar_url).to be_nil
    end

    it "returns nil for local user with avatar attached" do
      user = create(:user, :confirmed)
      user.avatar.attach(io: StringIO.new("fake"), filename: "avatar.png", content_type: "image/png")
      expect(user.effective_avatar_url).to be_nil
    end

    it "returns remote avatar URL for remote user" do
      user = create(:user, :remote)
      user.remote_user_detail.update!(avatar_url: "http://home.chat/avatar.png")
      expect(user.effective_avatar_url).to eq("http://home.chat/avatar.png")
    end

    it "returns nil for remote user without remote avatar" do
      user = create(:user, :remote)
      user.remote_user_detail.update!(avatar_url: nil)
      expect(user.effective_avatar_url).to be_nil
    end
  end

  describe "#effective_banner_url" do
    it "returns remote banner URL for remote user" do
      user = create(:user, :remote)
      user.remote_user_detail.update!(banner_url: "http://home.chat/banner.png")
      expect(user.effective_banner_url).to eq("http://home.chat/banner.png")
    end

    it "returns nil for local user" do
      user = create(:user, :confirmed)
      expect(user.effective_banner_url).to be_nil
    end
  end
end
