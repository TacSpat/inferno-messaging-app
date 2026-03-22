import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'nostr_key.dart';
import 'bech32_nostr.dart';
import 'nip44_crypto.dart';

class Nip49Crypto {
  static const int _version = 0x02;
  static const int _scryptR = 8;
  static const int _scryptP = 1;
  static const int _saltBytes = 16;
  static const int _nonceBytes = 24;
  static const int _keyBytes = 32;
  static const int _tagBytes = 16;

  /// Encrypt a hex private key with a password, returning "ncryptsec1..." string
  /// logN: scrypt cost parameter (16 = ~1s)
  /// keySecurity: 0x00=exposed, 0x01=not exposed, 0x02=unknown
  static String encrypt(String hexPrivKey, String password,
      {int logN = 16, int keySecurity = 0x02}) {
    final privKeyBytes = NostrKey.hexToBytes(hexPrivKey);
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List.generate(_saltBytes, (_) => random.nextInt(256)),
    );
    final nonce = Uint8List.fromList(
      List.generate(_nonceBytes, (_) => random.nextInt(256)),
    );
    final ad = Uint8List.fromList([keySecurity]);

    // Derive symmetric key via scrypt
    final symKey = _scryptDerive(password, salt, logN);

    // XChaCha20-Poly1305 encrypt with AD
    final ciphertext = _xChaCha20Poly1305EncryptWithAd(
      privKeyBytes,
      symKey,
      nonce,
      ad,
    );

    // NIP-49 payload: version(1) + log_n(1) + salt(16) + nonce(24) + ad(1) + ciphertext(48) = 91 bytes
    final payload = Uint8List(91);
    payload[0] = _version;
    payload[1] = logN;
    payload.setRange(2, 2 + _saltBytes, salt);
    payload.setRange(18, 18 + _nonceBytes, nonce);
    payload[42] = keySecurity;
    payload.setRange(43, 91, ciphertext);

    return Bech32Nostr.encode('ncryptsec', payload);
  }

  /// Decrypt an "ncryptsec1..." string with a password, returning hex private key
  static String decrypt(String ncryptsecStr, String password) {
    final payload = Bech32Nostr.decode('ncryptsec', ncryptsecStr);
    if (payload.length != 91) {
      throw FormatException('Invalid NIP-49 payload size: ${payload.length}');
    }

    final version = payload[0];
    if (version != _version) {
      throw FormatException('Unsupported NIP-49 version: $version');
    }

    final logN = payload[1];
    final salt = Uint8List.fromList(payload.sublist(2, 18));
    final nonce = Uint8List.fromList(payload.sublist(18, 42));
    final keySecurity = payload[42];
    final ciphertext = Uint8List.fromList(payload.sublist(43, 91));
    final ad = Uint8List.fromList([keySecurity]);

    // Derive symmetric key via scrypt
    final symKey = _scryptDerive(password, salt, logN);

    // XChaCha20-Poly1305 decrypt with AD
    final plaintext = _xChaCha20Poly1305DecryptWithAd(
      ciphertext,
      symKey,
      nonce,
      ad,
    );

    return NostrKey.bytesToHex(plaintext);
  }

  static Uint8List _scryptDerive(String password, Uint8List salt, int logN) {
    final scrypt = Scrypt();
    final n = 1 << logN;
    final params = ScryptParameters(n, _scryptR, _scryptP, _keyBytes, salt);
    scrypt.init(params);
    final passwordBytes = Uint8List.fromList(utf8.encode(password));
    return scrypt.process(passwordBytes);
  }

  static Uint8List _xChaCha20Poly1305EncryptWithAd(
    Uint8List plaintext,
    Uint8List key,
    Uint8List nonce24,
    Uint8List ad,
  ) {
    final subkey = Nip44Crypto.hChaCha20(key, nonce24.sublist(0, 16));
    final nonce12 = Uint8List(12);
    nonce12.setRange(4, 12, nonce24.sublist(16, 24));

    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    final params = AEADParameters(
      KeyParameter(subkey),
      _tagBytes * 8,
      nonce12,
      ad,
    );
    cipher.init(true, params);

    final output = Uint8List(plaintext.length + _tagBytes);
    final len = cipher.processBytes(plaintext, 0, plaintext.length, output, 0);
    cipher.doFinal(output, len);
    return output;
  }

  static Uint8List _xChaCha20Poly1305DecryptWithAd(
    Uint8List ciphertext,
    Uint8List key,
    Uint8List nonce24,
    Uint8List ad,
  ) {
    final subkey = Nip44Crypto.hChaCha20(key, nonce24.sublist(0, 16));
    final nonce12 = Uint8List(12);
    nonce12.setRange(4, 12, nonce24.sublist(16, 24));

    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    final params = AEADParameters(
      KeyParameter(subkey),
      _tagBytes * 8,
      nonce12,
      ad,
    );
    cipher.init(false, params);

    final output = Uint8List(ciphertext.length - _tagBytes);
    final len =
        cipher.processBytes(ciphertext, 0, ciphertext.length, output, 0);
    cipher.doFinal(output, len);
    return output;
  }
}
