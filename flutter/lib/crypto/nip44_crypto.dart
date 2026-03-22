import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;
import 'package:crypto/crypto.dart' as hash_lib;
import 'nostr_key.dart';

class Nip44Crypto {
  static const int _version = 2;
  static const int _nonceBytes = 24;
  static const int _tagBytes = 16;

  /// Compute ECDH shared secret (x-coordinate only)
  static Uint8List sharedSecret(String ourPrivKeyHex, String theirPubKeyHex) {
    final curve = ECCurve_secp256k1();
    final privKey = BigInt.parse(ourPrivKeyHex, radix: 16);

    // Reconstruct their public point from x-coordinate
    final theirX = BigInt.parse(theirPubKeyHex, radix: 16);
    final fpCurve = curve.curve as fp.ECCurve;
    final p = fpCurve.q!;
    final ySquared = (theirX.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
    final y = ySquared.modPow((p + BigInt.one) ~/ BigInt.from(4), p);
    final yFinal = y.isEven ? y : p - y; // Use even y (compressed 02 prefix)

    final theirPoint = fpCurve.createPoint(theirX, yFinal, false);

    // Scalar multiplication
    final sharedPoint = theirPoint * privKey;
    if (sharedPoint == null || sharedPoint.isInfinity) {
      throw StateError('ECDH failed: result is infinity');
    }

    // x-coordinate only, 32 bytes
    final xHex =
        sharedPoint.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
    return NostrKey.hexToBytes(xHex);
  }

  /// Derive conversation key using HKDF-SHA256 with salt "nip44-v2"
  static Uint8List conversationKey(
      String ourPrivKeyHex, String theirPubKeyHex) {
    final secret = sharedSecret(ourPrivKeyHex, theirPubKeyHex);
    return _hkdfExtractExpand(secret, 'nip44-v2');
  }

  /// Encrypt plaintext using NIP-44 v2
  static String encrypt(String plaintext, Uint8List convKey) {
    final random = Random.secure();
    final nonce = Uint8List.fromList(
      List.generate(_nonceBytes, (_) => random.nextInt(256)),
    );

    final padded = _padPlaintext(plaintext);
    final keys = _deriveMessageKeys(convKey, nonce);

    // XChaCha20-Poly1305 encrypt
    final encrypted = _xChaCha20Poly1305Encrypt(
      padded,
      keys.chachaKey,
      keys.chachaNonce,
    );

    // Build payload: version(1) + nonce(24) + ciphertext_with_tag
    final payload = Uint8List(1 + _nonceBytes + encrypted.length);
    payload[0] = _version;
    payload.setRange(1, 1 + _nonceBytes, nonce);
    payload.setRange(1 + _nonceBytes, payload.length, encrypted);

    // HMAC-SHA256 for authentication
    final mac = _hmacSha256(keys.hmacKey, payload);

    // Final: payload + mac
    final result = Uint8List(payload.length + 32);
    result.setRange(0, payload.length, payload);
    result.setRange(payload.length, result.length, mac);

    return base64.encode(result);
  }

  /// Decrypt NIP-44 v2 ciphertext
  static String decrypt(String encoded, Uint8List convKey) {
    final raw = base64.decode(encoded);
    if (raw.length < 1 + _nonceBytes + _tagBytes + 32 + 2) {
      throw FormatException('NIP-44 payload too short');
    }

    final version = raw[0];
    if (version != _version) {
      throw FormatException('Unsupported NIP-44 version: $version');
    }

    final nonce = Uint8List.fromList(raw.sublist(1, 1 + _nonceBytes));
    final mac = Uint8List.fromList(raw.sublist(raw.length - 32));
    final payload = Uint8List.fromList(raw.sublist(0, raw.length - 32));
    final ciphertext = Uint8List.fromList(
      raw.sublist(1 + _nonceBytes, raw.length - 32),
    );

    final keys = _deriveMessageKeys(convKey, nonce);

    // Verify HMAC
    final expectedMac = _hmacSha256(keys.hmacKey, payload);
    if (!_secureCompare(mac, expectedMac)) {
      throw FormatException('NIP-44 HMAC verification failed');
    }

    // XChaCha20-Poly1305 decrypt
    final plaintext = _xChaCha20Poly1305Decrypt(
      ciphertext,
      keys.chachaKey,
      keys.chachaNonce,
    );

    return _unpadPlaintext(plaintext);
  }

  // --- Private helpers ---

  static Uint8List _hkdfExtractExpand(Uint8List ikm, String saltStr) {
    final salt = Uint8List.fromList(utf8.encode(saltStr));
    // Extract
    final prk = _hmacSha256(salt, ikm);
    // Expand (single block)
    return _hmacSha256(prk, Uint8List.fromList([0x01]));
  }

  static _MessageKeys _deriveMessageKeys(Uint8List convKey, Uint8List nonce) {
    // t1 = HMAC(conv_key, nonce || 0x01)
    final t1Input = Uint8List(nonce.length + 1);
    t1Input.setRange(0, nonce.length, nonce);
    t1Input[nonce.length] = 0x01;
    final t1 = _hmacSha256(convKey, t1Input);

    // t2 = HMAC(conv_key, t1 || nonce || 0x02)
    final t2Input = Uint8List(32 + nonce.length + 1);
    t2Input.setRange(0, 32, t1);
    t2Input.setRange(32, 32 + nonce.length, nonce);
    t2Input[t2Input.length - 1] = 0x02;
    final t2 = _hmacSha256(convKey, t2Input);

    return _MessageKeys(
      chachaKey: t1,
      chachaNonce: Uint8List.fromList(t2.sublist(0, _nonceBytes)),
      hmacKey: t2,
    );
  }

  /// NIP-44 padding: 2-byte big-endian length + content + zeros to next power of 2, min 32
  static Uint8List _padPlaintext(String text) {
    final utf8Bytes = utf8.encode(text);
    final len = utf8Bytes.length;
    if (len > 65535) throw ArgumentError('Message too long');

    // Calculate padded length
    int paddedLen = 32;
    if (len + 2 > 32) {
      paddedLen = 1;
      while (paddedLen < len + 2) {
        paddedLen *= 2;
      }
    }
    if (paddedLen > 65536) paddedLen = 65536;

    final result = Uint8List(paddedLen);
    result[0] = (len >> 8) & 0xFF;
    result[1] = len & 0xFF;
    result.setRange(2, 2 + len, utf8Bytes);
    // Remaining bytes are already zero
    return result;
  }

  static String _unpadPlaintext(Uint8List padded) {
    if (padded.length < 2) throw FormatException('Padded text too short');
    final len = (padded[0] << 8) | padded[1];
    if (len + 2 > padded.length) throw FormatException('Invalid length prefix');
    return utf8.decode(padded.sublist(2, 2 + len));
  }

  static Uint8List _hmacSha256(Uint8List key, Uint8List data) {
    final hmac = hash_lib.Hmac(hash_lib.sha256, key);
    return Uint8List.fromList(hmac.convert(data).bytes);
  }

  static bool _secureCompare(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  /// HChaCha20: derive subkey from first 16 bytes of extended nonce
  /// Public so NIP-49 can reuse it for XChaCha20-Poly1305
  static Uint8List hChaCha20(Uint8List key, Uint8List nonce16) {
    // HChaCha20 state initialization
    final state = Uint32List(16);
    state[0] = 0x61707865; // "expa"
    state[1] = 0x3320646e; // "nd 3"
    state[2] = 0x79622d32; // "2-by"
    state[3] = 0x6b206574; // "te k"

    // Key (8 words)
    for (int i = 0; i < 8; i++) {
      state[4 + i] = _littleEndian32(key, i * 4);
    }

    // Nonce (4 words from first 16 bytes)
    for (int i = 0; i < 4; i++) {
      state[12 + i] = _littleEndian32(nonce16, i * 4);
    }

    // 20 rounds of ChaCha
    final working = Uint32List.fromList(state);
    for (int i = 0; i < 10; i++) {
      _quarterRound(working, 0, 4, 8, 12);
      _quarterRound(working, 1, 5, 9, 13);
      _quarterRound(working, 2, 6, 10, 14);
      _quarterRound(working, 3, 7, 11, 15);
      _quarterRound(working, 0, 5, 10, 15);
      _quarterRound(working, 1, 6, 11, 12);
      _quarterRound(working, 2, 7, 8, 13);
      _quarterRound(working, 3, 4, 9, 14);
    }

    // Output: first 4 words and last 4 words
    final subkey = Uint8List(32);
    for (int i = 0; i < 4; i++) {
      _writeLE32(subkey, i * 4, working[i]);
    }
    for (int i = 0; i < 4; i++) {
      _writeLE32(subkey, 16 + i * 4, working[12 + i]);
    }
    return subkey;
  }

  static void _quarterRound(Uint32List s, int a, int b, int c, int d) {
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF;
    s[d] ^= s[a];
    s[d] = _rotl32(s[d], 16);
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF;
    s[b] ^= s[c];
    s[b] = _rotl32(s[b], 12);
    s[a] = (s[a] + s[b]) & 0xFFFFFFFF;
    s[d] ^= s[a];
    s[d] = _rotl32(s[d], 8);
    s[c] = (s[c] + s[d]) & 0xFFFFFFFF;
    s[b] ^= s[c];
    s[b] = _rotl32(s[b], 7);
  }

  static int _rotl32(int v, int n) =>
      ((v << n) | (v >> (32 - n))) & 0xFFFFFFFF;

  static int _littleEndian32(Uint8List b, int i) =>
      b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

  static void _writeLE32(Uint8List b, int i, int v) {
    b[i] = v & 0xFF;
    b[i + 1] = (v >> 8) & 0xFF;
    b[i + 2] = (v >> 16) & 0xFF;
    b[i + 3] = (v >> 24) & 0xFF;
  }

  /// XChaCha20-Poly1305 encrypt using HChaCha20 for key derivation
  static Uint8List _xChaCha20Poly1305Encrypt(
    Uint8List plaintext,
    Uint8List key,
    Uint8List nonce24,
  ) {
    // HChaCha20 subkey derivation
    final subkey = hChaCha20(key, nonce24.sublist(0, 16));

    // Build 12-byte nonce: 4 zero bytes + last 8 bytes of 24-byte nonce
    final nonce12 = Uint8List(12);
    nonce12.setRange(4, 12, nonce24.sublist(16, 24));

    // Use pointycastle ChaCha20-Poly1305
    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    final params = AEADParameters(
      KeyParameter(subkey),
      _tagBytes * 8,
      nonce12,
      Uint8List(0), // no AAD
    );
    cipher.init(true, params);

    final output = Uint8List(plaintext.length + _tagBytes);
    final len = cipher.processBytes(plaintext, 0, plaintext.length, output, 0);
    cipher.doFinal(output, len);

    return output;
  }

  /// XChaCha20-Poly1305 decrypt
  static Uint8List _xChaCha20Poly1305Decrypt(
    Uint8List ciphertext,
    Uint8List key,
    Uint8List nonce24,
  ) {
    final subkey = hChaCha20(key, nonce24.sublist(0, 16));

    final nonce12 = Uint8List(12);
    nonce12.setRange(4, 12, nonce24.sublist(16, 24));

    final cipher = ChaCha20Poly1305(ChaCha7539Engine(), Poly1305());
    final params = AEADParameters(
      KeyParameter(subkey),
      _tagBytes * 8,
      nonce12,
      Uint8List(0),
    );
    cipher.init(false, params);

    final output = Uint8List(ciphertext.length - _tagBytes);
    final len =
        cipher.processBytes(ciphertext, 0, ciphertext.length, output, 0);
    cipher.doFinal(output, len);

    return output;
  }
}

class _MessageKeys {
  final Uint8List chachaKey;
  final Uint8List chachaNonce;
  final Uint8List hmacKey;

  _MessageKeys({
    required this.chachaKey,
    required this.chachaNonce,
    required this.hmacKey,
  });
}
