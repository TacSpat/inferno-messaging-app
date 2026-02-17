require 'rails_helper'

RSpec.describe NostrEventService do
  include NostrTestHelpers

  let(:private_key) { test_private_key }
  let(:public_key) { test_public_key }

  describe ".build_auth_event and .verify_auth_event round-trip" do
    let(:challenge) { SecureRandom.hex(32) }
    let(:relay_url) { "https://remote.chat/auth/nostr/callback" }
    let(:user) do
      user = create(:user, :confirmed, nostr_public_key: public_key)
      allow(user).to receive(:nostr_private_key).and_return(private_key)
      user
    end

    it "builds and verifies a valid auth event" do
      signed_event = NostrEventService.build_auth_event(
        user: user,
        challenge: challenge,
        relay_url: relay_url
      )

      verified = NostrEventService.verify_auth_event(signed_event, expected_challenge: challenge)

      expect(verified["pubkey"]).to eq(public_key)
      expect(verified["kind"]).to eq(22242)
    end

    it "accepts both Hash and String input" do
      signed_event = NostrEventService.build_auth_event(
        user: user,
        challenge: challenge,
        relay_url: relay_url
      )

      # As string
      verified = NostrEventService.verify_auth_event(
        JSON.generate(signed_event),
        expected_challenge: challenge
      )
      expect(verified["pubkey"]).to eq(public_key)

      # As hash (with string keys)
      hash_event = JSON.parse(JSON.generate(signed_event))
      verified2 = NostrEventService.verify_auth_event(
        hash_event,
        expected_challenge: challenge
      )
      expect(verified2["pubkey"]).to eq(public_key)
    end
  end

  describe ".verify_auth_event rejections" do
    let(:challenge) { SecureRandom.hex(32) }

    it "rejects wrong kind" do
      event = { "kind" => 1, "pubkey" => public_key, "sig" => "x", "id" => "x", "tags" => [] }
      expect {
        NostrEventService.verify_auth_event(event, expected_challenge: challenge)
      }.to raise_error(NostrEventService::InvalidEvent, /Missing event kind/)
    end

    it "rejects missing pubkey" do
      event = { "kind" => 22242, "pubkey" => "", "sig" => "x", "id" => "x", "tags" => [] }
      expect {
        NostrEventService.verify_auth_event(event, expected_challenge: challenge)
      }.to raise_error(NostrEventService::InvalidEvent, /Missing pubkey/)
    end

    it "rejects missing signature" do
      event = { "kind" => 22242, "pubkey" => "abc", "sig" => "", "id" => "x", "tags" => [] }
      expect {
        NostrEventService.verify_auth_event(event, expected_challenge: challenge)
      }.to raise_error(NostrEventService::InvalidEvent, /Missing signature/)
    end

    it "rejects missing challenge tag" do
      event = { "kind" => 22242, "pubkey" => "abc", "sig" => "x", "id" => "x", "tags" => [] }
      expect {
        NostrEventService.verify_auth_event(event, expected_challenge: challenge)
      }.to raise_error(NostrEventService::InvalidEvent, /Missing challenge tag/)
    end

    it "rejects challenge mismatch" do
      event = {
        "kind" => 22242, "pubkey" => "abc", "sig" => "x", "id" => "x",
        "tags" => [ [ "challenge", "wrong_challenge" ] ]
      }
      expect {
        NostrEventService.verify_auth_event(event, expected_challenge: challenge)
      }.to raise_error(NostrEventService::InvalidEvent, /Challenge mismatch/)
    end

    it "rejects tampered event ID" do
      event = {
        "kind" => 22242, "pubkey" => public_key, "sig" => "x",
        "id" => "tampered_id", "created_at" => Time.now.to_i, "content" => "",
        "tags" => [ [ "challenge", challenge ] ]
      }
      expect {
        NostrEventService.verify_auth_event(event, expected_challenge: challenge)
      }.to raise_error(NostrEventService::InvalidEvent, /Event ID mismatch/)
    end

    it "rejects expired events" do
      user = create(:user, :confirmed, nostr_public_key: public_key)
      allow(user).to receive(:nostr_private_key).and_return(private_key)

      signed_event = NostrEventService.build_auth_event(
        user: user,
        challenge: challenge,
        relay_url: "https://example.com"
      )

      event_data = JSON.parse(JSON.generate(signed_event))
      # Tamper with created_at to make it old
      event_data["created_at"] = 20.minutes.ago.to_i

      # Recalculate ID to match the tampered timestamp
      serialized = [ 0, event_data["pubkey"], event_data["created_at"], event_data["kind"],
                    event_data["tags"], event_data["content"] || "" ]
      event_data["id"] = Digest::SHA256.hexdigest(JSON.generate(serialized))

      expect {
        NostrEventService.verify_auth_event(event_data, expected_challenge: challenge)
      }.to raise_error(NostrEventService::InvalidSignature)
    end
  end

  describe ".verify_schnorr_signature" do
    it "raises InvalidSignature for bad signatures" do
      expect {
        NostrEventService.verify_schnorr_signature(
          message_hex: "a" * 64,
          pubkey_hex: "b" * 64,
          signature_hex: "c" * 128
        )
      }.to raise_error(NostrEventService::InvalidSignature)
    end
  end
end
