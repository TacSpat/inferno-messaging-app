import 'dart:typed_data';
import 'package:bech32/bech32.dart';

class Bech32Nostr {
  static const _maxLength = 300; // ncryptsec strings are ~162 chars

  /// Encode bytes to a bech32 string with the given HRP
  static String encode(String hrp, Uint8List data) {
    final data5bit = _convertBits(data, 8, 5, true);
    final bech32Data = Bech32(hrp, data5bit);
    return bech32.encode(bech32Data, _maxLength);
  }

  /// Decode a bech32 string, verify HRP, return the data bytes
  static Uint8List decode(String expectedHrp, String bech32Str) {
    final decoded = bech32.decode(bech32Str, _maxLength);
    if (decoded.hrp != expectedHrp) {
      throw FormatException(
        'Expected HRP "$expectedHrp", got "${decoded.hrp}"',
      );
    }
    return Uint8List.fromList(_convertBits(
      Uint8List.fromList(decoded.data),
      5,
      8,
      false,
    ));
  }

  /// Encode a 32-byte hex key as npub1...
  static String npubEncode(String hexPubKey) {
    return encode('npub', _hexToBytes(hexPubKey));
  }

  /// Encode a 32-byte hex key as nsec1...
  static String nsecEncode(String hexPrivKey) {
    return encode('nsec', _hexToBytes(hexPrivKey));
  }

  /// Decode npub1... to hex public key
  static String npubDecode(String npub) {
    final bytes = decode('npub', npub);
    return _bytesToHex(bytes);
  }

  /// Decode nsec1... to hex private key
  static String nsecDecode(String nsec) {
    final bytes = decode('nsec', nsec);
    return _bytesToHex(bytes);
  }

  /// Check if a string is a valid npub
  static bool isNpub(String s) {
    try {
      npubDecode(s);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Check if a string is a valid nsec
  static bool isNsec(String s) {
    try {
      nsecDecode(s);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Check if a string is a valid ncryptsec
  static bool isNcryptsec(String s) {
    try {
      decode('ncryptsec', s);
      return true;
    } catch (_) {
      return false;
    }
  }

  // --- Bit conversion (BIP-173) ---

  static List<int> _convertBits(
      Uint8List data, int fromBits, int toBits, bool pad) {
    int acc = 0;
    int bits = 0;
    final result = <int>[];
    final maxv = (1 << toBits) - 1;

    for (final value in data) {
      if (value < 0 || (value >> fromBits) != 0) {
        throw FormatException('Invalid value: $value');
      }
      acc = (acc << fromBits) | value;
      bits += fromBits;
      while (bits >= toBits) {
        bits -= toBits;
        result.add((acc >> bits) & maxv);
      }
    }

    if (pad) {
      if (bits > 0) {
        result.add((acc << (toBits - bits)) & maxv);
      }
    } else {
      if (bits >= fromBits) {
        throw FormatException('Invalid padding');
      }
      if (((acc << (toBits - bits)) & maxv) != 0) {
        throw FormatException('Non-zero padding');
      }
    }

    return result;
  }

  static Uint8List _hexToBytes(String hex) {
    final normalized = hex.length.isOdd ? '0$hex' : hex;
    return Uint8List.fromList(
      List.generate(
          normalized.length ~/ 2,
          (i) =>
              int.parse(normalized.substring(i * 2, i * 2 + 2), radix: 16)),
    );
  }

  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
