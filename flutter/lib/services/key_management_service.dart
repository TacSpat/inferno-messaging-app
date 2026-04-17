import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import '../crypto/nostr_key.dart';
import '../crypto/nip49_crypto.dart';
import '../crypto/bech32_nostr.dart';

/// Stored account entry for the multi-account picker. The ncryptsec is kept
/// in secure storage so the user can switch accounts without re-importing.
class StoredAccount {
  final String pubkey;
  final String npub;
  final String displayName;
  // ncryptsec is only in secure storage, never exposed via this class.
  StoredAccount({required this.pubkey, required this.npub, required this.displayName});

  Map<String, dynamic> toJson() => {'pubkey': pubkey, 'npub': npub, 'displayName': displayName};
  factory StoredAccount.fromJson(Map<String, dynamic> j) => StoredAccount(
    pubkey: j['pubkey'] as String,
    npub: j['npub'] as String,
    displayName: j['displayName'] as String? ?? '',
  );
}

class KeyManagementService {
  static const _storage = FlutterSecureStorage();
  static const _privKeyKey = 'nostr_private_key';
  static const _pubKeyKey = 'nostr_public_key';
  static const _backupPwHashKey = 'backup_password_hash';
  static const _accountListKey = 'account_list';
  static const _activeAccountKey = 'active_account';

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

  /// Delete the stored keypair (active account only — account list preserved)
  static Future<void> deleteKey() async {
    await _storage.delete(key: _privKeyKey);
    await _storage.delete(key: _pubKeyKey);
  }

  // ─── nsec export (clipboard only, never displayed) ───────────────

  /// Export the raw private key as nsec1... bech32. The caller copies to
  /// clipboard; the returned string must NEVER be assigned to a widget's
  /// state or rendered in a Text widget.
  static Future<String> exportNsec() async {
    final privHex = await _storage.read(key: _privKeyKey);
    if (privHex == null) throw StateError('No key stored');
    return Bech32Nostr.nsecEncode(privHex);
  }

  // ─── File export / import ────────────────────────────────────────

  /// Write [ncryptsec] to a `.key` file in the documents directory.
  /// Returns the full file path so the UI can show where it was saved.
  static Future<String> exportToFile(String ncryptsec) async {
    final dir = await getApplicationDocumentsDirectory();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final path = '${dir.path}/inferno-backup-$ts.key';
    await File(path).writeAsString(ncryptsec);
    return path;
  }

  /// Read a `.key` file and return its contents (trimmed). The caller
  /// feeds the result into the existing nsec/ncryptsec import flow.
  static Future<String> importFromFile(String filePath) async {
    return (await File(filePath).readAsString()).trim();
  }

  // ─── Backup password hash ────────────────────────────────────────

  /// Store a SHA-256 hash of the backup password. Used to verify the
  /// user knows their password before changing it. The password itself
  /// is never stored.
  static Future<void> setBackupPasswordHash(String password) async {
    final hash = sha256.convert(utf8.encode(password)).toString();
    await _storage.write(key: _backupPwHashKey, value: hash);
  }

  /// Verify a password against the stored hash.
  static Future<bool> verifyBackupPassword(String password) async {
    final stored = await _storage.read(key: _backupPwHashKey);
    if (stored == null) return false;
    return sha256.convert(utf8.encode(password)).toString() == stored;
  }

  /// Check whether a backup password has ever been set.
  static Future<bool> hasBackupPassword() async {
    return (await _storage.read(key: _backupPwHashKey)) != null;
  }

  // ─── Multi-account storage ───────────────────────────────────────

  /// List all saved accounts (pubkey + npub + display name).
  /// The ncryptsec strings are in secure storage but not returned here.
  static Future<List<StoredAccount>> listAccounts() async {
    final raw = await _storage.read(key: _accountListKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List;
      return list.map((e) => StoredAccount.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  /// Save the currently active account's ncryptsec into the account list
  /// so it can be re-selected after logout. Called during the mandatory
  /// backup step.
  static Future<void> storeCurrentAsAccount(String ncryptsec, String displayName) async {
    final pubHex = await _storage.read(key: _pubKeyKey);
    if (pubHex == null) throw StateError('No active key');
    final npub = Bech32Nostr.npubEncode(pubHex);
    final accounts = await listAccounts();
    // Update if already in list, else append.
    final idx = accounts.indexWhere((a) => a.pubkey == pubHex);
    final entry = StoredAccount(pubkey: pubHex, npub: npub, displayName: displayName);
    if (idx >= 0) {
      accounts[idx] = entry;
    } else {
      accounts.add(entry);
    }
    await _storage.write(key: _accountListKey, value: json.encode(accounts.map((a) => a.toJson()).toList()));
    // Store ncryptsec under a per-account key.
    await _storage.write(key: 'ncryptsec_$pubHex', value: ncryptsec);
    await _storage.write(key: _activeAccountKey, value: pubHex);
  }

  /// Add an external account (from import). Decrypts to verify the
  /// password is correct, stores the ncryptsec for future switching.
  static Future<NostrKey> addAccount(String ncryptsec, String password, String displayName) async {
    final privHex = Nip49Crypto.decrypt(ncryptsec, password);
    final key = NostrKey.fromPrivateKey(privHex);
    final npub = Bech32Nostr.npubEncode(key.publicKeyHex);
    final accounts = await listAccounts();
    final idx = accounts.indexWhere((a) => a.pubkey == key.publicKeyHex);
    final entry = StoredAccount(pubkey: key.publicKeyHex, npub: npub, displayName: displayName);
    if (idx >= 0) {
      accounts[idx] = entry;
    } else {
      accounts.add(entry);
    }
    await _storage.write(key: _accountListKey, value: json.encode(accounts.map((a) => a.toJson()).toList()));
    await _storage.write(key: 'ncryptsec_${key.publicKeyHex}', value: ncryptsec);
    return key;
  }

  /// Switch to a different saved account. Decrypts the stored ncryptsec
  /// and makes it the active key. Caller must re-bootstrap the app.
  static Future<NostrKey> switchAccount(String pubkey, String password) async {
    final ncryptsec = await _storage.read(key: 'ncryptsec_$pubkey');
    if (ncryptsec == null) throw StateError('Account not found in storage');
    final privHex = Nip49Crypto.decrypt(ncryptsec, password);
    final key = NostrKey.fromPrivateKey(privHex);
    await _storage.write(key: _privKeyKey, value: key.privateKeyHex);
    await _storage.write(key: _pubKeyKey, value: key.publicKeyHex);
    await _storage.write(key: _activeAccountKey, value: pubkey);
    return key;
  }

  /// Remove a saved account from the list. If it was the active account,
  /// also clears the active key.
  static Future<void> removeAccount(String pubkey) async {
    final accounts = await listAccounts();
    accounts.removeWhere((a) => a.pubkey == pubkey);
    await _storage.write(key: _accountListKey, value: json.encode(accounts.map((a) => a.toJson()).toList()));
    await _storage.delete(key: 'ncryptsec_$pubkey');
    final active = await _storage.read(key: _activeAccountKey);
    if (active == pubkey) {
      await deleteKey();
      await _storage.delete(key: _activeAccountKey);
    }
  }

  /// Get the active account's pubkey hex (if any).
  static Future<String?> getActiveAccountPubkey() async {
    return _storage.read(key: _activeAccountKey);
  }
}
