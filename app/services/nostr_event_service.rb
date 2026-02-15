class NostrEventService
  NIP42_AUTH_KIND = 22242

  class InvalidSignature < StandardError; end
  class InvalidEvent < StandardError; end

  # Build a NIP-42 auth event for cross-instance authentication
  # Returns a signed event hash ready for JSON encoding
  def self.build_auth_event(user:, challenge:, relay_url:)
    signer = Nostr::Signer.new(private_key: user.nostr_private_key)

    event = Nostr::Event.new(
      kind: NIP42_AUTH_KIND,
      pubkey: user.nostr_public_key,
      content: "",
      tags: [
        ["relay", relay_url],
        ["challenge", challenge]
      ]
    )

    signed = signer.sign(event)
    signed.to_json
  end

  # Verify a signed NIP-42 auth event
  # Returns the parsed event data if valid, raises on failure
  def self.verify_auth_event(event_json, expected_challenge:)
    event_data = case event_json
    when String then JSON.parse(event_json)
    when Hash then event_json.deep_stringify_keys
    else event_json
    end

    # Check required fields
    raise InvalidEvent, "Missing event kind" unless event_data["kind"] == NIP42_AUTH_KIND
    raise InvalidEvent, "Missing pubkey" if event_data["pubkey"].blank?
    raise InvalidEvent, "Missing signature" if event_data["sig"].blank?
    raise InvalidEvent, "Missing event id" if event_data["id"].blank?

    pubkey = event_data["pubkey"]
    tags = event_data["tags"] || []

    # Verify challenge tag matches
    challenge_tag = tags.find { |t| t[0] == "challenge" }
    raise InvalidEvent, "Missing challenge tag" unless challenge_tag
    raise InvalidEvent, "Challenge mismatch" unless challenge_tag[1] == expected_challenge

    # Verify event ID is correct (SHA256 of serialized event)
    serialized = [
      0,
      pubkey,
      event_data["created_at"],
      event_data["kind"],
      tags,
      event_data["content"] || ""
    ]
    expected_id = Digest::SHA256.hexdigest(JSON.generate(serialized))
    raise InvalidEvent, "Event ID mismatch" unless event_data["id"] == expected_id

    # Verify Schnorr signature
    verify_schnorr_signature(
      message_hex: event_data["id"],
      pubkey_hex: pubkey,
      signature_hex: event_data["sig"]
    )

    # Check event is recent (within 10 minutes)
    event_time = Time.at(event_data["created_at"])
    raise InvalidEvent, "Event too old" if event_time < 10.minutes.ago
    raise InvalidEvent, "Event from the future" if event_time > 1.minute.from_now

    event_data
  end

  # Verify a Schnorr signature using the bip-schnorr gem
  def self.verify_schnorr_signature(message_hex:, pubkey_hex:, signature_hex:)
    message_bin = [message_hex].pack("H*")
    pubkey_bin = [pubkey_hex].pack("H*")
    signature_bin = [signature_hex].pack("H*")

    Schnorr.check_sig!(message_bin, pubkey_bin, signature_bin)
    true
  rescue => e
    raise InvalidSignature, "Schnorr signature verification failed: #{e.message}"
  end
end
