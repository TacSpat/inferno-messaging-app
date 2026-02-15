require 'rails_helper'

RSpec.describe RemoteUser, type: :model do
  describe "validations" do
    subject { build(:remote_user) }

    it { should validate_presence_of(:nostr_public_key) }
    it { should validate_uniqueness_of(:nostr_public_key) }
    it { should validate_presence_of(:home_instance) }
    it { should validate_length_of(:username).is_at_most(32) }
  end

  describe "associations" do
    it { should have_one(:shadow_user).class_name("User").with_foreign_key(:remote_user_detail_id).dependent(:destroy) }
  end

  describe ".find_or_create_from_auth" do
    let(:pubkey) { SecureRandom.hex(32) }

    it "creates a RemoteUser and shadow User pair" do
      remote_user = RemoteUser.find_or_create_from_auth(
        public_key: pubkey,
        home_instance: "remote.chat",
        username: "alice",
        display_name: "Alice"
      )

      expect(remote_user).to be_persisted
      expect(remote_user.nostr_public_key).to eq(pubkey)
      expect(remote_user.home_instance).to eq("remote.chat")
      expect(remote_user.username).to eq("alice")

      remote_user.reload
      shadow = remote_user.shadow_user
      expect(shadow).to be_present
      expect(shadow.remote?).to be true
      expect(shadow.email).to include(pubkey[0..15])
    end

    it "reuses existing RemoteUser on second call" do
      remote_user1 = RemoteUser.find_or_create_from_auth(
        public_key: pubkey,
        home_instance: "remote.chat"
      )

      remote_user2 = RemoteUser.find_or_create_from_auth(
        public_key: pubkey,
        home_instance: "remote.chat",
        display_name: "Updated Name"
      )

      expect(remote_user2.id).to eq(remote_user1.id)
      expect(remote_user2.display_name).to eq("Updated Name")
    end

    it "creates shadow user with default username when none provided" do
      remote_user = RemoteUser.find_or_create_from_auth(
        public_key: pubkey,
        home_instance: "remote.chat"
      )

      remote_user.reload
      expect(remote_user.shadow_user.username).to start_with("remote_")
    end
  end

  describe "#nip05_identifier" do
    it "returns the NIP-05 identifier" do
      remote_user = build(:remote_user, username: "alice", home_instance: "remote.chat")
      expect(remote_user.nip05_identifier).to eq("alice@remote.chat")
    end

    it "returns nil when username is blank" do
      remote_user = build(:remote_user, username: nil)
      expect(remote_user.nip05_identifier).to be_nil
    end
  end

  describe "#normalize_home_instance" do
    it "downcases and strips the home instance" do
      remote_user = create(:remote_user, home_instance: "  REMOTE.Chat  ")
      expect(remote_user.home_instance).to eq("remote.chat")
    end
  end
end
