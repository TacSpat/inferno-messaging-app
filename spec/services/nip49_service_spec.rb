require 'rails_helper'

RSpec.describe Nip49Service do
  let(:test_privkey) { "5a26e4b9a456a8e8e1bf01a5e26ca7c25e5aea1f3b7e0c8d9f2a1b3c4d5e6f70" }
  let(:password) { "correct horse battery staple" }

  describe ".encrypt and .decrypt round-trip" do
    it "encrypts and decrypts a private key" do
      ncryptsec = Nip49Service.encrypt(test_privkey, password, log_n: 8)

      expect(ncryptsec).to start_with("ncryptsec1")

      decrypted = Nip49Service.decrypt(ncryptsec, password)
      expect(decrypted).to eq(test_privkey)
    end

    it "works with different key_security values" do
      [0x00, 0x01, 0x02].each do |ks|
        ncryptsec = Nip49Service.encrypt(test_privkey, password, log_n: 8, key_security: ks)
        decrypted = Nip49Service.decrypt(ncryptsec, password)
        expect(decrypted).to eq(test_privkey)
      end
    end

    it "produces different ciphertexts for same input (random salt/nonce)" do
      enc1 = Nip49Service.encrypt(test_privkey, password, log_n: 8)
      enc2 = Nip49Service.encrypt(test_privkey, password, log_n: 8)
      expect(enc1).not_to eq(enc2)
    end
  end

  describe ".decrypt" do
    it "rejects wrong password" do
      ncryptsec = Nip49Service.encrypt(test_privkey, password, log_n: 8)

      expect {
        Nip49Service.decrypt(ncryptsec, "wrong password")
      }.to raise_error(Nip49Service::DecryptionError, /Decryption failed/)
    end

    it "rejects invalid ncryptsec format" do
      expect {
        Nip49Service.decrypt("nsec1invalid", password)
      }.to raise_error(Nip49Service::DecryptionError, /Invalid ncryptsec format/)
    end
  end

  describe "NIP-49 spec compliance" do
    it "produces a valid bech32-encoded ncryptsec string" do
      ncryptsec = Nip49Service.encrypt(test_privkey, password, log_n: 8)

      # Verify the bech32 structure
      hrp, _data, _spec = Bech32.decode(ncryptsec, ncryptsec.length)
      expect(hrp).to eq("ncryptsec")
    end

    it "handles unicode passwords via NFKC normalization" do
      unicode_password = "p\u00E4ssw\u00F6rd"
      ncryptsec = Nip49Service.encrypt(test_privkey, unicode_password, log_n: 8)
      decrypted = Nip49Service.decrypt(ncryptsec, unicode_password)
      expect(decrypted).to eq(test_privkey)
    end
  end
end
