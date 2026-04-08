import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../crypto/nostr_key.dart';
import '../crypto/nip49_crypto.dart';
import '../crypto/bech32_nostr.dart';

class KeyManagementService {
  static const _storage = FlutterSecureStorage();
  static const _privKeyKey = 'nostr_private_key';
  static const _pubKeyKey = 'nostr_public_key';

  /// Generate a new keypair and store it securely
  static Future<NostrKey> generateAndStore() async {
    final key = NostrKey.generate();
    await _storage.write(key: _privKeyKey, value: key.privateKeyHex);
    await _storage.write(key: _pubKeyKey, value: key.publicKeyHex);
    return key;
  }

  /// Load the stored keypair (returns null if not set up)
  static Future<NostrKey?> load() async {
    final privHex = await _storage.read(key: _privKeyKey);
    if (privHex == null) return null;
    return NostrKey.fromPrivateKey(privHex);
  }

  /// Get just the public key hex (without loading private key)
  static Future<String?> getPublicKey() async {
    return await _storage.read(key: _pubKeyKey);
  }

  /// Import from nsec (raw private key in bech32)
  static Future<NostrKey> importNsec(String nsec) async {
    final privHex = Bech32Nostr.nsecDecode(nsec);
    final key = NostrKey.fromPrivateKey(privHex);
    await _storage.write(key: _privKeyKey, value: key.privateKeyHex);
    await _storage.write(key: _pubKeyKey, value: key.publicKeyHex);
    return key;
  }

  /// Import from ncryptsec (password-encrypted private key)
  static Future<NostrKey> importNcryptsec(
      String ncryptsec, String password) async {
    final privHex = Nip49Crypto.decrypt(ncryptsec, password);
    final key = NostrKey.fromPrivateKey(privHex);
    await _storage.write(key: _privKeyKey, value: key.privateKeyHex);
    await _storage.write(key: _pubKeyKey, value: key.publicKeyHex);
    return key;
  }

  /// Export as ncryptsec (password-encrypted)
  static Future<String> exportNcryptsec(String password,
      {int logN = 16}) async {
    final privHex = await _storage.read(key: _privKeyKey);
    if (privHex == null) throw StateError('No key stored');
    return Nip49Crypto.encrypt(privHex, password, logN: logN);
  }

  /// Export as npub (public key in bech32)
  static Future<String> exportNpub() async {
    final pubHex = await _storage.read(key: _pubKeyKey);
    if (pubHex == null) throw StateError('No key stored');
    return Bech32Nostr.npubEncode(pubHex);
  }

  /// Check if a keypair is stored
  static Future<bool> hasKey() async {
    final key = await _storage.read(key: _privKeyKey);
    return key != null;
  }

  /// Delete the stored keypair
  static Future<void> deleteKey() async {
    await _storage.delete(key: _privKeyKey);
    await _storage.delete(key: _pubKeyKey);
  }
}
