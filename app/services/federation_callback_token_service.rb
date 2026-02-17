class FederationCallbackTokenService
  TOKEN_EXPIRY = 30.days

  def self.generate(from_pubkey:, to_pubkey:)
    verifier.generate(
      { from_pubkey: from_pubkey, to_pubkey: to_pubkey, issued_at: Time.current.to_i },
      purpose: :friend_request_callback
    )
  end

  def self.verify(token)
    payload = verifier.verified(token, purpose: :friend_request_callback)
    return nil unless payload

    issued_at = Time.at(payload[:issued_at] || payload["issued_at"] || 0)
    return nil if issued_at < TOKEN_EXPIRY.ago

    payload.with_indifferent_access
  end

  private

  def self.verifier
    @verifier ||= ActiveSupport::MessageVerifier.new(
      Rails.application.secret_key_base + "friend_request_callbacks"
    )
  end
end
