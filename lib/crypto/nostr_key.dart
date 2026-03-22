import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

class NostrKey {
  final String privateKeyHex;
  final String publicKeyHex;

  NostrKey._({required this.privateKeyHex, required this.publicKeyHex});

  /// Generate a new random Nostr keypair
  factory NostrKey.generate() {
    final secureRandom = FortunaRandom();
    final seedSource = Random.secure();
    final seeds = List<int>.generate(32, (_) => seedSource.nextInt(256));
    secureRandom.seed(KeyParameter(Uint8List.fromList(seeds)));

    final curveParams = ECCurve_secp256k1();
    final n = curveParams.n;

    // Generate private key in valid range [1, n-1]
    BigInt privKey;
    do {
      final bytes = secureRandom.nextBytes(32);
      privKey = _bytesToBigInt(bytes);
    } while (privKey == BigInt.zero || privKey >= n);

    final privKeyHex = privKey.toRadixString(16).padLeft(64, '0');
    final pubKeyHex = getPublicKey(privKeyHex);

    return NostrKey._(privateKeyHex: privKeyHex, publicKeyHex: pubKeyHex);
  }

  /// Create from an existing private key hex string
  factory NostrKey.fromPrivateKey(String privateKeyHex) {
    final normalized = privateKeyHex.toLowerCase().padLeft(64, '0');
    final pubKeyHex = getPublicKey(normalized);
    return NostrKey._(privateKeyHex: normalized, publicKeyHex: pubKeyHex);
  }

  /// Derive public key (x-coordinate only, 32 bytes hex) from private key
  static String getPublicKey(String privateKeyHex) {
    final curveParams = ECCurve_secp256k1();
    final privKey = BigInt.parse(privateKeyHex, radix: 16);
    final pubPoint = curveParams.G * privKey;
    if (pubPoint == null || pubPoint.isInfinity) {
      throw ArgumentError('Invalid private key');
    }
    // x-coordinate only (32 bytes)
    return pubPoint.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
  }

  /// Convert hex string to bytes
  static Uint8List hexToBytes(String hex) {
    final normalized = hex.length.isOdd ? '0$hex' : hex;
    return Uint8List.fromList(
      List.generate(normalized.length ~/ 2,
          (i) => int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16)),
    );
  }

  /// Convert bytes to hex string
  static String bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    BigInt result = BigInt.zero;
    for (int i = 0; i < bytes.length; i++) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }
}
