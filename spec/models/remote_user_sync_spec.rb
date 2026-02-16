require 'rails_helper'

RSpec.describe RemoteUser, "#sync_from_profile_data", type: :model do
  let(:remote_user) do
    create(:remote_user, username: "alice", display_name: "Alice", home_instance: "home.chat")
  end
  let!(:shadow) do
    user = User.new(
      username: "alice",
      display_name: "Alice",
      email: "nostr+test@home.chat",
      password: SecureRandom.hex(32),
      remote: true,
      remote_user_detail: remote_user,
      public_id: SecureRandom.alphanumeric(12)
    )
    user.skip_confirmation!
    user.save!(validate: false)
    user
  end

  let(:profile_data) do
    {
      "username" => "alice",
      "display_name" => "Alice Updated",
      "discriminator" => "1234",
      "bio" => "Hello world",
      "profile_color" => "#ff5500",
      "profile_color_2" => "#003355",
      "banner_offset_y" => 42,
      "status" => "Coding",
      "status_emoji" => "💻",
      "avatar_url" => "http://home.chat/avatar.png",
      "banner_url" => "http://home.chat/banner.png"
    }
  end

  it "updates remote user cached fields" do
    remote_user.sync_from_profile_data(profile_data)
    remote_user.reload

    expect(remote_user.display_name).to eq("Alice Updated")
    expect(remote_user.discriminator).to eq("1234")
    expect(remote_user.bio).to eq("Hello world")
    expect(remote_user.profile_color).to eq("#ff5500")
    expect(remote_user.profile_color_2).to eq("#003355")
    expect(remote_user.banner_offset_y).to eq(42)
    expect(remote_user.status).to eq("Coding")
    expect(remote_user.avatar_url).to eq("http://home.chat/avatar.png")
    expect(remote_user.banner_url).to eq("http://home.chat/banner.png")
    expect(remote_user.last_profile_sync_at).to be_within(2.seconds).of(Time.current)
  end

  it "syncs display fields to shadow user" do
    remote_user.sync_from_profile_data(profile_data)
    shadow.reload

    expect(shadow.display_name).to eq("Alice Updated")
    expect(shadow.bio).to eq("Hello world")
    expect(shadow.profile_color).to eq("#ff5500")
    expect(shadow.profile_color_2).to eq("#003355")
    expect(shadow.banner_offset_y).to eq(42)
    expect(shadow.status).to eq("Coding")
    expect(shadow.status_emoji).to eq("💻")
  end

  it "does not overwrite with blank values for presence-checked fields" do
    remote_user.sync_from_profile_data(profile_data)
    remote_user.sync_from_profile_data({ "display_name" => "", "avatar_url" => "" })
    remote_user.reload

    expect(remote_user.display_name).to eq("Alice Updated")
    expect(remote_user.avatar_url).to eq("http://home.chat/avatar.png")
  end

  it "clears nullable fields when key is present with nil" do
    remote_user.sync_from_profile_data(profile_data)
    remote_user.sync_from_profile_data({ "bio" => nil, "status" => nil })
    remote_user.reload

    expect(remote_user.bio).to be_nil
    expect(remote_user.status).to be_nil
  end
end

RSpec.describe RemoteUser, ".find_or_create_from_auth with new fields", type: :model do
  let(:pubkey) { SecureRandom.hex(32) }

  it "stores profile_color and discriminator" do
    remote_user = RemoteUser.find_or_create_from_auth(
      public_key: pubkey,
      home_instance: "home.chat",
      username: "bob",
      profile_color: "#aabbcc",
      discriminator: "0420"
    )

    expect(remote_user.profile_color).to eq("#aabbcc")
    expect(remote_user.discriminator).to eq("0420")
  end

  it "passes profile_color to shadow user on creation" do
    remote_user = RemoteUser.find_or_create_from_auth(
      public_key: pubkey,
      home_instance: "home.chat",
      username: "bob",
      profile_color: "#aabbcc"
    )

    remote_user.reload
    expect(remote_user.shadow_user.profile_color).to eq("#aabbcc")
  end
end
