require 'rails_helper'

RSpec.describe RemoteUser, "#find_or_create_from_auth discriminator" do
  it "assigns a valid 4-digit discriminator to shadow users" do
    remote_user = RemoteUser.find_or_create_from_auth(
      public_key: SecureRandom.hex(32),
      home_instance: "remote.chat",
      username: "testremote",
      display_name: "Test Remote"
    )

    shadow = remote_user.shadow_user
    expect(shadow).to be_present
    expect(shadow.discriminator).to match(/\A\d{4}\z/)
    expect(shadow.discriminator).not_to eq("0000")
  end

  it "assigns unique discriminators for same username" do
    # Create a local user with a specific username
    create(:user, :confirmed, username: "sharedname")

    remote_user = RemoteUser.find_or_create_from_auth(
      public_key: SecureRandom.hex(32),
      home_instance: "remote.chat",
      username: "sharedname",
      display_name: "Shared Name"
    )

    shadow = remote_user.shadow_user
    local = User.local.find_by(username: "sharedname")

    expect(shadow.discriminator).not_to eq(local.discriminator)
  end
end
