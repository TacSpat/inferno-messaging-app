module HasNostrIdentity
  extend ActiveSupport::Concern

  included do
    after_create :generate_nostr_keypair, unless: -> { nostr_public_key? || (respond_to?(:remote?) && remote?) }
  end

  # Decrypted private key (hex)
  def nostr_private_key
    return nil if nostr_encrypted_private_key.blank?
    encryptor.decrypt_and_verify(nostr_encrypted_private_key)
  end

  # Public key in bech32 npub format
  def npub
    return nil if nostr_public_key.blank?
    Nostr::Bech32.encode_npub(nostr_public_key)
  end

  # Private key in bech32 nsec format
  def nsec
    key = nostr_private_key
    return nil if key.blank?
    Nostr::Bech32.encode_nsec(key)
  end

  # NIP-05 identifier (e.g. "tac@inferno.chat")
  def nip05_identifier
    "#{username.downcase}@#{Rails.application.config.x.instance_domain}"
  end

  def generate_nostr_keypair
    private_key = Nostr::Key.generate_private_key
    public_key = Nostr::Key.get_public_key(private_key)

    self.nostr_public_key = public_key
    self.nostr_encrypted_private_key = encryptor.encrypt_and_sign(private_key)
    save!(validate: false) if persisted?
  end

  private

  def encryptor
    key = ActiveSupport::KeyGenerator.new(
      Rails.application.credentials.secret_key_base
    ).generate_key("nostr keypair encryption", 32)
    ActiveSupport::MessageEncryptor.new(key)
  end
end
