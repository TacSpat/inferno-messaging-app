import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../crypto/nip44_crypto.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';

/// Syncs app configuration across devices via encrypted Kind 30078 events
/// (NIP-78 application-specific data). Content is NIP-44 encrypted with
/// the user's own key so only they can read it.
class ConfigSyncService {
  final RelayPool _relayPool;
  static const _storage = FlutterSecureStorage();
  Timer? _publishTimer;
  Map<String, dynamic>? _pendingConfig;

  ConfigSyncService(this._relayPool);

  // ─── App Settings ────────────────────────────────────────

  /// Publish app configuration to relays. Debounced: call this on every
  /// settings change and it batches them into a single publish after 5s
  /// of quiet.
  void schedulePublish({
    required String privateKeyHex,
    required String publicKeyHex,
    required Map<String, dynamic> config,
  }) {
    _pendingConfig = config;
    _publishTimer?.cancel();
    _publishTimer = Timer(const Duration(seconds: 5), () {
      _publishConfig(
        privateKeyHex: privateKeyHex,
        publicKeyHex: publicKeyHex,
        config: _pendingConfig!,
        dTag: 'inferno-config',
      );
      _pendingConfig = null;
    });
  }

  /// Fetch and decrypt the latest app config from relays.
  Future<Map<String, dynamic>?> fetchConfig({
    required String privateKeyHex,
    required String publicKeyHex,
  }) async {
    return _fetchEncryptedJson(
      privateKeyHex: privateKeyHex,
      publicKeyHex: publicKeyHex,
      dTag: 'inferno-config',
    );
  }

  // ─── Server List ─────────────────────────────────────────

  /// Publish the list of servers the user belongs to so a fresh device
  /// knows which servers to sync.
  Future<void> publishServerList({
    required String privateKeyHex,
    required String publicKeyHex,
    required List<String> serverGroupIds,
  }) async {
    await _publishConfig(
      privateKeyHex: privateKeyHex,
      publicKeyHex: publicKeyHex,
      config: {'servers': serverGroupIds},
      dTag: 'inferno-servers',
    );
  }

  /// Fetch the list of server group IDs from relays.
  Future<List<String>> fetchServerList({
    required String privateKeyHex,
    required String publicKeyHex,
  }) async {
    final data = await _fetchEncryptedJson(
      privateKeyHex: privateKeyHex,
      publicKeyHex: publicKeyHex,
      dTag: 'inferno-servers',
    );
    if (data == null) return [];
    final servers = data['servers'];
    if (servers is List) return servers.cast<String>();
    return [];
  }

  // ─── Internals ───────────────────────────────────────────

  Future<void> _publishConfig({
    required String privateKeyHex,
    required String publicKeyHex,
    required Map<String, dynamic> config,
    required String dTag,
  }) async {
    try {
      // NIP-44 encrypt to self (conversation key with own pubkey).
      final plaintext = json.encode(config);
      final convKey = Nip44Crypto.conversationKey(privateKeyHex, publicKeyHex);
      final encrypted = Nip44Crypto.encrypt(plaintext, convKey);

      final event = nostr.NostrEvent(
        pubkey: publicKeyHex,
        createdAt: nostr.NostrEvent.now(),
        kind: 30078,
        tags: [['d', dTag]],
        content: encrypted,
      );
      final signer = NostrSigner(privateKeyHex: privateKeyHex);
      final signed = signer.sign(event);
      await _relayPool.publish(signed);
      debugPrint('[ConfigSync] Published Kind 30078 d=$dTag');
    } catch (e) {
      debugPrint('[ConfigSync] Publish failed (d=$dTag): $e');
    }
  }

  Future<Map<String, dynamic>?> _fetchEncryptedJson({
    required String privateKeyHex,
    required String publicKeyHex,
    required String dTag,
  }) async {
    try {
      final filter = NostrFilter(
        kinds: [30078],
        authors: [publicKeyHex],
        tags: {'#d': [dTag]},
        limit: 1,
      );
      final events = await _relayPool.fetch(filter, timeout: const Duration(seconds: 8));
      if (events.isEmpty) return null;

      events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      final convKey = Nip44Crypto.conversationKey(privateKeyHex, publicKeyHex);
      final plaintext = Nip44Crypto.decrypt(events.first.content, convKey);
      return json.decode(plaintext) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[ConfigSync] Fetch failed (d=$dTag): $e');
      return null;
    }
  }

  void dispose() {
    _publishTimer?.cancel();
  }
}
