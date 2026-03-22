import 'dart:typed_data';
import 'package:pointycastle/export.dart';
import 'package:pointycastle/ecc/ecc_fp.dart' as fp;
import 'package:crypto/crypto.dart' as crypto_lib;
import 'nostr_key.dart';
import 'nostr_event.dart';

class NostrVerifier {
  /// Verify a complete Nostr event (check ID + signature)
  static bool verifyEvent(NostrEvent event) {
    if (event.id == null || event.sig == null) return false;

    // Verify event ID
    final computedId = event.computeId();
    if (computedId != event.id) return false;

    // Verify Schnorr signature
    return verifySchnorr(
      messageHash: NostrKey.hexToBytes(event.id!),
      publicKeyHex: event.pubkey,
      signatureHex: event.sig!,
    );
  }

  /// BIP-340 Schnorr signature verification
  static bool verifySchnorr({
    required Uint8List messageHash,
    required String publicKeyHex,
    required String signatureHex,
  }) {
    try {
      final curve = ECCurve_secp256k1();
      final n = curve.n;
      final G = curve.G;
      final fpCurve = curve.curve as fp.ECCurve;
      final p = fpCurve.q!;

      if (messageHash.length != 32) return false;
      final sigBytes = NostrKey.hexToBytes(signatureHex);
      if (sigBytes.length != 64) return false;

      final rx = _bytesToBigInt(sigBytes.sublist(0, 32));
      final s = _bytesToBigInt(sigBytes.sublist(32, 64));

      if (rx >= p) return false;
      if (s >= n) return false;

      // Lift x to point P
      final px = BigInt.parse(publicKeyHex, radix: 16);
      final P = _liftX(px, curve);
      if (P == null) return false;

      // e = tagged_hash("BIP0340/challenge", R.x || P.x || msg) mod n
      final rxBytes = _bigIntToBytes(rx, 32);
      final pxBytes = _bigIntToBytes(px, 32);
      final challengeInput = Uint8List(96);
      challengeInput.setRange(0, 32, rxBytes);
      challengeInput.setRange(32, 64, pxBytes);
      challengeInput.setRange(64, 96, messageHash);
      final eHash = _taggedHash('BIP0340/challenge', challengeInput);
      final e = _bytesToBigInt(eHash) % n;

      // R = s*G - e*P
      final sG = G * s;
      final eP = P * e;
      if (sG == null || eP == null) return false;

      // Negate eP
      final ePNeg = fpCurve.createPoint(
        eP.x!.toBigInteger()!,
        (p - eP.y!.toBigInteger()!) % p,
        eP.isCompressed,
      );

      final R = sG + ePNeg;
      if (R == null || R.isInfinity) return false;

      final ry = R.y!.toBigInteger()!;
      if (ry.isOdd) return false;

      final rPointX = R.x!.toBigInteger()!;
      return rPointX == rx;
    } catch (_) {
      return false;
    }
  }

  /// Lift an x-coordinate to a secp256k1 point (even y)
  static ECPoint? _liftX(BigInt x, ECCurve_secp256k1 curve) {
    final fpCurve = curve.curve as fp.ECCurve;
    final p = fpCurve.q!;
    if (x >= p) return null;

    // y^2 = x^3 + 7 mod p
    final ySquared = (x.modPow(BigInt.from(3), p) + BigInt.from(7)) % p;
    final y = ySquared.modPow((p + BigInt.one) ~/ BigInt.from(4), p);

    if (y.modPow(BigInt.two, p) != ySquared) return null;

    final yFinal = y.isEven ? y : p - y;
    return fpCurve.createPoint(x, yFinal, false);
  }

  static Uint8List _taggedHash(String tag, Uint8List data) {
    final tagHash = crypto_lib.sha256.convert(tag.codeUnits).bytes;
    final input = Uint8List(tagHash.length * 2 + data.length);
    input.setRange(0, tagHash.length, tagHash);
    input.setRange(tagHash.length, tagHash.length * 2, tagHash);
    input.setRange(tagHash.length * 2, input.length, data);
    return Uint8List.fromList(crypto_lib.sha256.convert(input).bytes);
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final hex = value.toRadixString(16).padLeft(length * 2, '0');
    return NostrKey.hexToBytes(hex);
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    BigInt result = BigInt.zero;
    for (int i = 0; i < bytes.length; i++) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }
}
