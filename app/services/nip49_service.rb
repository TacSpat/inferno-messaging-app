require "fiddle"
require "fiddle/import"
require "openssl"
require "securerandom"

# NIP-49: Encrypted private key export/import using scrypt + XChaCha20-Poly1305.
# Produces bech32-encoded "ncryptsec" strings that users can back up safely.
class Nip49Service
  LIB = Fiddle.dlopen("libsodium.so.23")

  # int sodium_init(void)
  SODIUM_INIT = Fiddle::Function.new(
    LIB["sodium_init"], [], Fiddle::TYPE_INT
  )

  # int crypto_aead_xchacha20poly1305_ietf_encrypt(
  #   unsigned char *c, unsigned long long *clen_p,
  #   const unsigned char *m, unsigned long long mlen,
  #   const unsigned char *ad, unsigned long long adlen,
  #   const unsigned char *nsec,
  #   const unsigned char *npub,
  #   const unsigned char *k)
  ENCRYPT = Fiddle::Function.new(
    LIB["crypto_aead_xchacha20poly1305_ietf_encrypt"],
    [
      Fiddle::TYPE_VOIDP,      # c
      Fiddle::TYPE_VOIDP,      # clen_p
      Fiddle::TYPE_VOIDP,      # m
      Fiddle::TYPE_LONG_LONG,  # mlen
      Fiddle::TYPE_VOIDP,      # ad
      Fiddle::TYPE_LONG_LONG,  # adlen
      Fiddle::TYPE_VOIDP,      # nsec (always NULL)
      Fiddle::TYPE_VOIDP,      # npub (nonce)
      Fiddle::TYPE_VOIDP       # k (key)
    ],
    Fiddle::TYPE_INT
  )

  # int crypto_aead_xchacha20poly1305_ietf_decrypt(
  #   unsigned char *m, unsigned long long *mlen_p,
  #   unsigned char *nsec,
  #   const unsigned char *c, unsigned long long clen,
  #   const unsigned char *ad, unsigned long long adlen,
  #   const unsigned char *npub,
  #   const unsigned char *k)
  DECRYPT = Fiddle::Function.new(
    LIB["crypto_aead_xchacha20poly1305_ietf_decrypt"],
    [
      Fiddle::TYPE_VOIDP,      # m
      Fiddle::TYPE_VOIDP,      # mlen_p
      Fiddle::TYPE_VOIDP,      # nsec (always NULL)
      Fiddle::TYPE_VOIDP,      # c
      Fiddle::TYPE_LONG_LONG,  # clen
      Fiddle::TYPE_VOIDP,      # ad
      Fiddle::TYPE_LONG_LONG,  # adlen
      Fiddle::TYPE_VOIDP,      # npub (nonce)
      Fiddle::TYPE_VOIDP       # k (key)
    ],
    Fiddle::TYPE_INT
  )

  SODIUM_INIT.call

  VERSION          = 0x02
  SCRYPT_R         = 8
  SCRYPT_P         = 1
  SALT_BYTES       = 16
  NONCE_BYTES      = 24
  KEY_BYTES        = 32
  TAG_BYTES        = 16

  class DecryptionError < StandardError; end

  # Encrypt a hex private key with a password, returning an "ncryptsec1..." string.
  # log_n: scrypt cost parameter (16 = ~1s, 20 = ~16s). Higher = slower brute force.
  # key_security: 0x00 = exposed, 0x01 = not exposed, 0x02 = unknown
  def self.encrypt(hex_privkey, password, log_n: 16, key_security: 0x02)
    privkey_bytes = [ hex_privkey ].pack("H*")
    password_nfkc = password.unicode_normalize(:nfkc)
    salt          = SecureRandom.random_bytes(SALT_BYTES)
    nonce         = SecureRandom.random_bytes(NONCE_BYTES)
    ad            = [ key_security ].pack("C")

    sym_key = OpenSSL::KDF.scrypt(
      password_nfkc, salt: salt, N: 2**log_n, r: SCRYPT_R, p: SCRYPT_P, length: KEY_BYTES
    )

    ciphertext_buf = ("\x00" * (KEY_BYTES + TAG_BYTES)).b
    clen_buf       = ("\x00" * 8).b

    result = ENCRYPT.call(
      ciphertext_buf, clen_buf,
      privkey_bytes, privkey_bytes.bytesize,
      ad, ad.bytesize,
      nil, nonce, sym_key
    )
    raise "Encryption failed" unless result == 0

    # NIP-49 payload: version(1) + log_n(1) + salt(16) + nonce(24) + ad(1) + ciphertext(48) = 91 bytes
    payload = [ VERSION, log_n ].pack("CC") + salt + nonce + ad.b + ciphertext_buf

    data_5bit = Bech32.convert_bits(payload.bytes, 8, 5, true)
    Bech32.encode("ncryptsec", data_5bit, Bech32::Encoding::BECH32)
  end

  # Decrypt an "ncryptsec1..." string with a password, returning the hex private key.
  def self.decrypt(ncryptsec_str, password)
    hrp, data_5bit, _spec = Bech32.decode(ncryptsec_str, ncryptsec_str.length)
    raise DecryptionError, "Invalid ncryptsec format" unless hrp == "ncryptsec"

    payload = Bech32.convert_bits(data_5bit, 5, 8, false).pack("C*")
    raise DecryptionError, "Invalid payload size" unless payload.bytesize == 91

    version = payload.getbyte(0)
    raise DecryptionError, "Unsupported version: #{version}" unless version == VERSION

    log_n        = payload.getbyte(1)
    salt         = payload.byteslice(2, SALT_BYTES)
    nonce        = payload.byteslice(18, NONCE_BYTES)
    key_security = payload.getbyte(42)
    ciphertext   = payload.byteslice(43, KEY_BYTES + TAG_BYTES)
    ad           = [ key_security ].pack("C")

    password_nfkc = password.unicode_normalize(:nfkc)
    sym_key = OpenSSL::KDF.scrypt(
      password_nfkc, salt: salt, N: 2**log_n, r: SCRYPT_R, p: SCRYPT_P, length: KEY_BYTES
    )

    plaintext_buf = "\x00" * KEY_BYTES
    mlen_buf      = "\x00" * 8

    result = DECRYPT.call(
      plaintext_buf, mlen_buf, nil,
      ciphertext, ciphertext.bytesize,
      ad, ad.bytesize,
      nonce, sym_key
    )
    raise DecryptionError, "Decryption failed — wrong password or corrupted data" unless result == 0

    plaintext_buf.unpack1("H*")
  end
end
