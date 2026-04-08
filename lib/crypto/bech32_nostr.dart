import 'dart:convert';
import 'dart:typed_data';
import 'package:bech32/bech32.dart';

/// Decoded NIP-19 naddr data (parameterized replaceable event pointer).
class NaddrData {
  final String identifier;
  final int kind;
  final String pubkey;
  final List<String> relays;
  const NaddrData({required this.identifier, required this.kind, required this.pubkey, this.relays = const []});
}

class Bech32Nostr {
  static const _maxLength = 500; // naddr strings can be longer than npub/nsec

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

  // --- NIP-19 naddr (parameterized replaceable event pointer) ---

  /// Encode an naddr from its components using TLV format.
  /// TLV types: 0=identifier, 1=relay, 2=author(32-byte pubkey), 3=kind(4-byte BE uint32)
  static String naddrEncode({
    required String identifier,
    required int kind,
    required String pubkey,
    List<String> relays = const [],
  }) {
    final buf = BytesBuilder();

    // Type 0: identifier (UTF-8)
    final idBytes = utf8.encode(identifier);
    buf.addByte(0);
    buf.addByte(idBytes.length);
    buf.add(idBytes);

    // Type 1: relays (one TLV entry per relay)
    for (final relay in relays) {
      final relayBytes = utf8.encode(relay);
      buf.addByte(1);
      buf.addByte(relayBytes.length);
      buf.add(relayBytes);
    }

    // Type 2: author pubkey (32 bytes)
    final pubkeyBytes = _hexToBytes(pubkey);
    buf.addByte(2);
    buf.addByte(pubkeyBytes.length);
    buf.add(pubkeyBytes);

    // Type 3: kind (4-byte big-endian)
    buf.addByte(3);
    buf.addByte(4);
    buf.addByte((kind >> 24) & 0xFF);
    buf.addByte((kind >> 16) & 0xFF);
    buf.addByte((kind >> 8) & 0xFF);
    buf.addByte(kind & 0xFF);

    return encode('naddr', Uint8List.fromList(buf.toBytes()));
  }

  /// Decode an naddr string (with or without nostr: prefix) into its components.
  static NaddrData naddrDecode(String naddr) {
    final clean = naddr.startsWith('nostr:') ? naddr.substring(6) : naddr;
    final data = decode('naddr', clean);

    String identifier = '';
    int kind = 0;
    String pubkey = '';
    final relays = <String>[];

    int i = 0;
    while (i < data.length) {
      if (i + 1 >= data.length) break;
      final type = data[i];
      final len = data[i + 1];
      i += 2;
      if (i + len > data.length) break;
      final value = data.sublist(i, i + len);

      switch (type) {
        case 0: identifier = utf8.decode(value); break;
        case 1: relays.add(utf8.decode(value)); break;
        case 2: pubkey = _bytesToHex(Uint8List.fromList(value)); break;
        case 3:
          if (value.length == 4) {
            kind = (value[0] << 24) | (value[1] << 16) | (value[2] << 8) | value[3];
          }
          break;
      }
      i += len;
    }

    return NaddrData(identifier: identifier, kind: kind, pubkey: pubkey, relays: relays);
  }

  /// Convenience: encode an invite as naddr (compact format matching Rails to_naddr).
  static String inviteNaddr({
    required String serverPublicId,
    required String code,
    required String creatorPubkey,
    List<String> relays = const [],
  }) {
    return naddrEncode(
      identifier: 'inv-$serverPublicId-$code',
      kind: 31757,
      pubkey: creatorPubkey,
      relays: relays,
    );
  }

  /// Check if a string is a valid naddr
  static bool isNaddr(String s) {
    try {
      naddrDecode(s);
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
