require 'rails_helper'

RSpec.describe FederationProfileSyncJob, type: :job do
  let(:remote_user) do
    create(:remote_user,
      username: "alice",
      home_instance: "home.chat",
      federation_token: "test-token"
    )
  end
  let!(:shadow) do
    user = User.new(
      username: "alice",
      display_name: "alice",
      email: "nostr+sync@home.chat",
      password: SecureRandom.hex(32),
      remote: true,
      remote_user_detail: remote_user,
      public_id: SecureRandom.alphanumeric(12)
    )
    user.skip_confirmation!
    user.save!(validate: false)
    user
  end

  let(:profile_response) do
    {
      username: "alice",
      display_name: "Alice Updated",
      discriminator: "1234",
      bio: "Bio from home",
      profile_color: "#ff0000",
      profile_color_2: "#0000ff",
      banner_offset_y: 50,
      avatar_url: "http://home.chat/avatar.png",
      banner_url: "http://home.chat/banner.png"
    }.to_json
  end

  let(:servers_response) do
    {
      servers: [
        {
          server_id: "srv_abc",
          name: "Home Server",
          icon_url: nil,
          invite_code: "inv123",
          instance_url: "http://home.chat",
          member_count: 5,
          emojis: [],
          stickers: []
        }
      ]
    }.to_json
  end

  let(:conversations_response) do
    {
      conversations: [
        {
          conversation_id: "conv_xyz",
          kind: "direct",
          name: "Bob",
          other_user: { username: "bob", display_name: "Bob", avatar_url: nil, profile_color: "#333" },
          last_message_at: "2026-02-16T08:00:00Z",
          instance_url: "http://home.chat"
        }
      ]
    }.to_json
  end

  let(:gif_response) do
    {
      gif_collections: [
        {
          name: "Favorites",
          icon: nil,
          position: 0,
          favorites: [
            {
              tenor_gif_id: "gif123",
              tenor_url: "https://tenor.com/gif123",
              preview_url: "https://media.tenor.com/preview.gif",
              gif_url: "https://media.tenor.com/full.gif",
              description: "LOL",
              position: 0
            }
          ]
        }
      ]
    }.to_json
  end

  before do
    pubkey = remote_user.nostr_public_key
    base = "https://home.chat/federation/profiles/#{pubkey}"
    headers = { "Content-Type" => "application/json" }

    stub_request(:get, /#{Regexp.escape(base)}(\?|$)/).to_return(status: 200, body: profile_response, headers: headers)
    stub_request(:get, /#{Regexp.escape(base)}\/servers/).to_return(status: 200, body: servers_response, headers: headers)
    stub_request(:get, /#{Regexp.escape(base)}\/conversations/).to_return(status: 200, body: conversations_response, headers: headers)
    stub_request(:get, /#{Regexp.escape(base)}\/friends/).to_return(status: 200, body: { friends: [] }.to_json, headers: headers)
    stub_request(:get, /#{Regexp.escape(base)}\/folders/).to_return(status: 200, body: { folders: [] }.to_json, headers: headers)
    stub_request(:get, /#{Regexp.escape(base)}\/gif_collections/).to_return(status: 200, body: gif_response, headers: headers)
    stub_request(:post, /#{Regexp.escape(base)}\/report_memberships/).to_return(status: 200, body: { status: "ok" }.to_json, headers: headers)
  end

  it "syncs profile data to remote user and shadow" do
    described_class.perform_now(remote_user.id)

    remote_user.reload
    expect(remote_user.display_name).to eq("Alice Updated")
    expect(remote_user.profile_color).to eq("#ff0000")
    expect(remote_user.avatar_url).to eq("http://home.chat/avatar.png")
    expect(remote_user.last_profile_sync_at).to be_present

    shadow.reload
    expect(shadow.display_name).to eq("Alice Updated")
    expect(shadow.bio).to eq("Bio from home")
  end

  it "creates remote server references" do
    expect {
      described_class.perform_now(remote_user.id)
    }.to change(shadow.remote_server_references, :count).by(1)

    ref = shadow.remote_server_references.last
    expect(ref.name).to eq("Home Server")
    expect(ref.remote_server_id).to eq("srv_abc")
    expect(ref.invite_code).to eq("inv123")
  end

  it "creates remote conversation references" do
    expect {
      described_class.perform_now(remote_user.id)
    }.to change(shadow.remote_conversation_references, :count).by(1)

    ref = shadow.remote_conversation_references.last
    expect(ref.other_username).to eq("bob")
    expect(ref.kind).to eq("direct")
  end

  it "creates GIF collections and favorites" do
    expect {
      described_class.perform_now(remote_user.id)
    }.to change(shadow.gif_collections, :count).by(1)
     .and change(shadow.gif_favorites, :count).by(1)

    collection = shadow.gif_collections.find_by(name: "Favorites")
    expect(collection).to be_present
    fav = collection.gif_favorites.first
    expect(fav.tenor_gif_id).to eq("gif123")
  end

  it "includes federation token in requests" do
    described_class.perform_now(remote_user.id)

    expect(WebMock).to have_requested(:get, /federation\/profiles/)
      .with(headers: { "X-Federation-Token" => "test-token" })
      .at_least_once
  end

  it "handles missing remote user gracefully" do
    expect { described_class.perform_now(0) }.not_to raise_error
  end

  it "handles failed API responses gracefully" do
    stub_request(:get, /federation\/profiles/).to_return(status: 500)

    expect { described_class.perform_now(remote_user.id) }.not_to raise_error
  end
end
