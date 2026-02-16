class FederationTokenService
  TOKEN_EXPIRY = 30.days

  # Generate a signed federation token on the HOME instance.
  # Called during NIP-42 signing when a user authenticates to a remote instance.
  def self.generate(pubkey:, requesting_instance:)
    payload = {
      pubkey: pubkey,
      instance: requesting_instance,
      issued_at: Time.current.to_i
    }
    verifier.generate(payload, purpose: :federation_token)
  end

  # Verify a federation token on the HOME instance.
  # Returns the payload hash or nil if invalid/expired.
  def self.verify(token)
    payload = verifier.verified(token, purpose: :federation_token)
    return nil unless payload

    # Check expiration
    issued_at = Time.at(payload[:issued_at] || payload["issued_at"] || 0)
    return nil if issued_at < TOKEN_EXPIRY.ago

    payload.with_indifferent_access
  end

  private

  def self.verifier
    @verifier ||= ActiveSupport::MessageVerifier.new(
      Rails.application.credentials.secret_key_base + "federation_tokens"
    )
  end
end
