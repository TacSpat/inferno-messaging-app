require "fiddle"
require "fiddle/import"
require "openssl"
require "securerandom"

# NIP-44: Encrypted direct messages using ECDH + HKDF + XChaCha20-Poly1305.
# Reuses libsodium FFI from Nip49Service.
class Nip44Service
  LIB = Fiddle.dlopen(
    case RbConfig::CONFIG["host_os"]
    when /darwin/      then "libsodium.dylib"
    when /mingw|mswin/ then "libsodium.dll"
    else "libsodium.so.23"
    end
  )

  # crypto_scalarmult(q, n, p)
  SCALARMULT = Fiddle::Function.new(
    LIB["crypto_scalarmult"],
    [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP],
    Fiddle::TYPE_INT
  )

  ENCRYPT = Fiddle::Function.new(
    LIB["crypto_aead_xchacha20poly1305_ietf_encrypt"],
    [
      Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
      Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG,
      Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG,
      Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP
    ],
    Fiddle::TYPE_INT
  )

  DECRYPT = Fiddle::Function.new(
    LIB["crypto_aead_xchacha20poly1305_ietf_decrypt"],
    [
      Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP,
      Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG,
      Fiddle::TYPE_VOIDP, Fiddle::TYPE_LONG_LONG,
      Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP
    ],
    Fiddle::TYPE_INT
  )

  NONCE_BYTES = 24
  TAG_BYTES = 16
  VERSION = 2

  class EncryptionError < StandardError; end
  class DecryptionError < StandardError; end

  # Compute shared secret between our private key and their public key
  # NIP-44 uses x-only pubkeys (32 bytes), we prepend 0x02 for curve point
  def self.shared_secret(our_privkey_hex, their_pubkey_hex)
    # Convert x-only pubkey to compressed point (prepend 02)
    their_point = ["02#{their_pubkey_hex}"].pack("H*")

    # Our private key as 32 bytes (for X25519, but Nostr uses secp256k1)
    # NIP-44 uses secp256k1 ECDH
    our_priv_bn = OpenSSL::BN.new(our_privkey_hex, 16)
    group = OpenSSL::PKey::EC::Group.new("secp256k1")
    their_point_ec = OpenSSL::PKey::EC::Point.new(group, OpenSSL::BN.new(their_point, 2))

    # ECDH: multiply their point by our scalar
    shared_point = their_point_ec.mul(our_priv_bn)
    shared_x = shared_point.to_bn(:compressed).to_s(16)[2..65] # x coordinate only

    [shared_x].pack("H*")
  end

  # NIP-44 conversation key derivation
  def self.conversation_key(our_privkey_hex, their_pubkey_hex)
    secret = shared_secret(our_privkey_hex, their_pubkey_hex)
    # HKDF-SHA256 with salt "nip44-v2"
    hkdf_extract_expand(secret, "nip44-v2")
  end

  # Encrypt plaintext using NIP-44 v2
  def self.encrypt(plaintext, conversation_key)
    nonce = SecureRandom.random_bytes(NONCE_BYTES)
    padded = pad_plaintext(plaintext)

    # Derive message keys from conversation key and nonce
    keys = derive_message_keys(conversation_key, nonce)
    chacha_key = keys[:chacha_key]
    chacha_nonce = keys[:chacha_nonce]
    hmac_key = keys[:hmac_key]

    # XChaCha20-Poly1305 encrypt
    ciphertext_buf = ("\x00" * (padded.bytesize + TAG_BYTES)).b
    clen_buf = ("\x00" * 8).b

    result = ENCRYPT.call(
      ciphertext_buf, clen_buf,
      padded, padded.bytesize,
      nil, 0,
      nil, chacha_nonce, chacha_key
    )
    raise EncryptionError, "XChaCha20 encryption failed" unless result == 0

    # NIP-44 payload: version(1) + nonce(24) + ciphertext
    payload = [VERSION].pack("C") + nonce + ciphertext_buf

    # HMAC-SHA256 for authentication
    mac = OpenSSL::HMAC.digest("SHA256", hmac_key, payload)

    Base64.strict_encode64(payload + mac)
  end

  # Decrypt NIP-44 v2 ciphertext
  def self.decrypt(encoded, conversation_key)
    raw = Base64.strict_decode64(encoded)
    raise DecryptionError, "Too short" if raw.bytesize < 1 + NONCE_BYTES + TAG_BYTES + 32 + 2

    version = raw.getbyte(0)
    raise DecryptionError, "Unsupported NIP-44 version: #{version}" unless version == VERSION

    nonce = raw.byteslice(1, NONCE_BYTES)
    mac = raw.byteslice(-32, 32)
    payload = raw.byteslice(0, raw.bytesize - 32)
    ciphertext = raw.byteslice(1 + NONCE_BYTES, raw.bytesize - 1 - NONCE_BYTES - 32)

    # Derive message keys
    keys = derive_message_keys(conversation_key, nonce)
    chacha_key = keys[:chacha_key]
    chacha_nonce = keys[:chacha_nonce]
    hmac_key = keys[:hmac_key]

    # Verify HMAC
    expected_mac = OpenSSL::HMAC.digest("SHA256", hmac_key, payload)
    unless secure_compare(mac, expected_mac)
      raise DecryptionError, "HMAC verification failed"
    end

    # Decrypt
    plaintext_buf = ("\x00" * ciphertext.bytesize).b
    mlen_buf = ("\x00" * 8).b

    result = DECRYPT.call(
      plaintext_buf, mlen_buf, nil,
      ciphertext, ciphertext.bytesize,
      nil, 0,
      chacha_nonce, chacha_key
    )
    raise DecryptionError, "XChaCha20 decryption failed" unless result == 0

    unpad_plaintext(plaintext_buf)
  end

  private

  def self.hkdf_extract_expand(ikm, salt_str)
    salt = salt_str.encode("UTF-8")
    # Extract
    prk = OpenSSL::HMAC.digest("SHA256", salt, ikm)
    # Expand (single block, info = empty)
    OpenSSL::HMAC.digest("SHA256", prk, "\x01")
  end

  def self.derive_message_keys(conversation_key, nonce)
    # HKDF expand with nonce as info
    prk = conversation_key
    t1 = OpenSSL::HMAC.digest("SHA256", prk, nonce + "\x01")
    t2 = OpenSSL::HMAC.digest("SHA256", prk, t1 + nonce + "\x02")
    {
      chacha_key: t1,
      chacha_nonce: t2.byteslice(0, NONCE_BYTES),
      hmac_key: t2
    }
  end

  # NIP-44 padding: 2-byte big-endian length prefix + content + zero padding to next power of 2
  def self.pad_plaintext(text)
    utf8 = text.encode("UTF-8")
    len = utf8.bytesize
    raise EncryptionError, "Message too long" if len > 65535

    # Calculate padded length (next power of 2, minimum 32)
    padded_len = [32, 2**Math.log2([len + 2, 1].max).ceil].max
    padded_len = [padded_len, 65536].min

    result = [len].pack("n") + utf8 + ("\x00" * (padded_len - 2 - len))
    result.b
  end

  def self.unpad_plaintext(padded)
    raise DecryptionError, "Padded text too short" if padded.bytesize < 2
    len = padded.byteslice(0, 2).unpack1("n")
    raise DecryptionError, "Invalid length prefix" if len + 2 > padded.bytesize
    padded.byteslice(2, len).force_encoding("UTF-8")
  end

  def self.secure_compare(a, b)
    return false if a.bytesize != b.bytesize
    result = 0
    a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
    result == 0
  end
end
