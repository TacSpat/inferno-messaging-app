import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:crypto/crypto.dart' as crypto_lib;
import 'nostr_key.dart';
import 'nostr_event.dart';

class NostrSigner {
  final String _privateKeyHex;

  NostrSigner({required String privateKeyHex}) : _privateKeyHex = privateKeyHex;

  /// Sign a Nostr event, returning the event with id and sig populated
  NostrEvent sign(NostrEvent event) {
    final eventWithId = event.withComputedId();
    final messageBytes = NostrKey.hexToBytes(eventWithId.id!);
    final sigHex = signSchnorr(messageBytes);
    return eventWithId.withSignature(sigHex);
  }

  /// BIP-340 Schnorr signature
  /// Signs a 32-byte message hash with the private key
  String signSchnorr(Uint8List messageHash) {
    final curve = ECCurve_secp256k1();
    final n = curve.n;
    final G = curve.G;

    final d = BigInt.parse(_privateKeyHex, radix: 16);
    final P = G * d;
    if (P == null || P.isInfinity) throw StateError('Invalid private key');

    // BIP-340: negate d if P.y is odd
    final px = P.x!.toBigInteger()!;
    final py = P.y!.toBigInteger()!;
    final dNeg = py.isOdd ? n - d : d;

    // Deterministic nonce: aux = 32 zero bytes for simplicity
    // t = d XOR tagged_hash("BIP0340/aux", aux)
    final aux = Uint8List(32);
    final auxHash = _taggedHash('BIP0340/aux', aux);
    final dBytes = _bigIntToBytes(dNeg, 32);
    final t = Uint8List(32);
    for (int i = 0; i < 32; i++) {
      t[i] = dBytes[i] ^ auxHash[i];
    }

    // k' = tagged_hash("BIP0340/nonce", t || px_bytes || msg)
    final pxBytes = _bigIntToBytes(px, 32);
    final nonceInput = Uint8List(96);
    nonceInput.setRange(0, 32, t);
    nonceInput.setRange(32, 64, pxBytes);
    nonceInput.setRange(64, 96, messageHash);
    final kHash = _taggedHash('BIP0340/nonce', nonceInput);
    var k = _bytesToBigInt(kHash) % n;
    if (k == BigInt.zero) throw StateError('Nonce is zero');

    // R = k*G
    final R = G * k;
    if (R == null || R.isInfinity) throw StateError('R is infinity');

    // Negate k if R.y is odd
    final ry = R.y!.toBigInteger()!;
    if (ry.isOdd) k = n - k;

    final rx = R.x!.toBigInteger()!;
    final rxBytes = _bigIntToBytes(rx, 32);

    // e = tagged_hash("BIP0340/challenge", R.x || P.x || msg)
    final challengeInput = Uint8List(96);
    challengeInput.setRange(0, 32, rxBytes);
    challengeInput.setRange(32, 64, pxBytes);
    challengeInput.setRange(64, 96, messageHash);
    final eHash = _taggedHash('BIP0340/challenge', challengeInput);
    final e = _bytesToBigInt(eHash) % n;

    // s = (k + e * d') mod n
    final s = (k + e * dNeg) % n;

    // Signature = R.x (32 bytes) || s (32 bytes)
    final sig = Uint8List(64);
    sig.setRange(0, 32, rxBytes);
    sig.setRange(32, 64, _bigIntToBytes(s, 32));

    return NostrKey.bytesToHex(sig);
  }

  /// BIP-340 tagged hash: SHA256(SHA256(tag) || SHA256(tag) || data)
  Uint8List _taggedHash(String tag, Uint8List data) {
    final tagHash = crypto_lib.sha256.convert(tag.codeUnits).bytes;
    final input = Uint8List(tagHash.length * 2 + data.length);
    input.setRange(0, tagHash.length, tagHash);
    input.setRange(tagHash.length, tagHash.length * 2, tagHash);
    input.setRange(tagHash.length * 2, input.length, data);
    return Uint8List.fromList(crypto_lib.sha256.convert(input).bytes);
  }

  Uint8List _bigIntToBytes(BigInt value, int length) {
    final hex = value.toRadixString(16).padLeft(length * 2, '0');
    return NostrKey.hexToBytes(hex);
  }

  BigInt _bytesToBigInt(Uint8List bytes) {
    BigInt result = BigInt.zero;
    for (int i = 0; i < bytes.length; i++) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }
}
