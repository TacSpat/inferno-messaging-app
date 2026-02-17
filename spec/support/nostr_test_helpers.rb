module NostrTestHelpers
  # Deterministic test keypairs for reproducible tests
  TEST_PRIVATE_KEY = "5a26e4b9a456a8e8e1bf01a5e26ca7c25e5aea1f3b7e0c8d9f2a1b3c4d5e6f70"
  TEST_PUBLIC_KEY = Nostr::Key.get_public_key(TEST_PRIVATE_KEY)

  TEST_PRIVATE_KEY_2_REAL = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
  TEST_PUBLIC_KEY_2 = Nostr::Key.get_public_key(TEST_PRIVATE_KEY_2_REAL)

  INSTANCE_PRIVATE_KEY = "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
  INSTANCE_PUBLIC_KEY = Nostr::Key.get_public_key(INSTANCE_PRIVATE_KEY)

  def test_private_key
    NostrTestHelpers::TEST_PRIVATE_KEY
  end

  def test_public_key
    NostrTestHelpers::TEST_PUBLIC_KEY
  end

  def instance_private_key
    NostrTestHelpers::INSTANCE_PRIVATE_KEY
  end

  def instance_public_key
    NostrTestHelpers::INSTANCE_PUBLIC_KEY
  end

  def stub_relay_service
    allow(RelayService).to receive(:publish_to_all).and_return({})
    allow(RelayService).to receive(:publish_to_relay).and_return({ success: true, message: "OK" })
    allow(RelayService).to receive(:fetch_from_all).and_return([])
    allow(RelayService).to receive(:fetch_from_relay).and_return([])
  end

  def stub_instance_nostr_config
    Rails.application.config.nostr = {
      instance_private_key: NostrTestHelpers::INSTANCE_PRIVATE_KEY,
      instance_public_key: NostrTestHelpers::INSTANCE_PUBLIC_KEY
    }
  end

  def stub_action_cable
    allow(ChannelChatChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    allow(ServerChannel).to receive(:broadcast_to)
  end

  def build_signed_auth_event(private_key:, public_key:, challenge:, relay_url: "https://remote.chat/auth/nostr/callback")
    signer = Nostr::Signer.new(private_key: private_key)
    event = Nostr::Event.new(
      kind: 22242,
      pubkey: public_key,
      content: "",
      tags: [
        [ "relay", relay_url ],
        [ "challenge", challenge ]
      ]
    )
    signed = signer.sign(event)
    signed.to_json
  end
end
