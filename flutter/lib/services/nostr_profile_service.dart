import 'dart:convert';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import '../crypto/nostr_event.dart' as crypto;
import '../crypto/nostr_signer.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';
import 'relay_config_service.dart';
import 'server_publish_service.dart';

class NostrProfileService {
  final RelayPool _relayPool;
  final InfernoDatabase _db;

  NostrProfileService(this._relayPool, this._db);

  /// Publish a Kind 0 profile metadata event, update local contact record,
  /// and republish member events to all servers (matches Rails flow).
  Future<Map<String, bool>> publishProfile({
    required String privateKeyHex,
    required String publicKeyHex,
    required String username,
    String? displayName,
    String? about,
    String? pictureUrl,
    String? bannerUrl,
    String? nip05,
    String? status,
    String? statusEmoji,
  }) async {
    final profileData = <String, dynamic>{
      'name': username,
    };
    if (displayName != null && displayName.isNotEmpty) {
      profileData['display_name'] = displayName;
    }
    if (about != null && about.isNotEmpty) {
      profileData['about'] = about;
    }
    if (pictureUrl != null && pictureUrl.isNotEmpty) {
      profileData['picture'] = pictureUrl;
    }
    if (bannerUrl != null && bannerUrl.isNotEmpty) {
      profileData['banner'] = bannerUrl;
    }
    if (nip05 != null && nip05.isNotEmpty) {
      profileData['nip05'] = nip05;
    }
    if (status != null && status.isNotEmpty) {
      profileData['status'] = status;
    }
    if (statusEmoji != null && statusEmoji.isNotEmpty) {
      profileData['status_emoji'] = statusEmoji;
    }

    final event = crypto.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: crypto.NostrEvent.now(),
      kind: 0,
      tags: [],
      content: json.encode(profileData),
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    final results = await _relayPool.publish(signed);

    // Update local contact record (matches Rails after_update_commit :broadcast_profile_update)
    await _updateLocalContact(
      publicKeyHex: publicKeyHex,
      username: username,
      displayName: displayName,
      about: about,
      pictureUrl: pictureUrl,
      bannerUrl: bannerUrl,
      nip05: nip05,
      status: status,
      statusEmoji: statusEmoji,
    );

    // Republish member events to all servers (matches Rails publish_member_events)
    _republishMemberEvents(privateKeyHex: privateKeyHex, publicKeyHex: publicKeyHex);

    return results;
  }

  /// Update the local contact record with new profile data.
  Future<void> _updateLocalContact({
    required String publicKeyHex,
    required String username,
    String? displayName,
    String? about,
    String? pictureUrl,
    String? bannerUrl,
    String? nip05,
    String? status,
    String? statusEmoji,
  }) async {
    try {
      final now = DateTime.now();
      final existing = await _db.contactsDao.getByPubkey(publicKeyHex);
      if (existing != null) {
        await (_db.update(_db.contacts)..where((c) => c.pubkey.equals(publicKeyHex)))
            .write(ContactsCompanion(
          username: Value(username),
          displayName: Value(displayName ?? username),
          bio: Value(about),
          avatarUrl: Value(pictureUrl),
          bannerUrl: Value(bannerUrl),
          nip05: Value(nip05),
          status: Value(status),
          statusEmoji: Value(statusEmoji),
          profileFetchedAt: Value(now),
          updatedAt: Value(now),
        ));
      } else {
        await _db.into(_db.contacts).insert(ContactsCompanion.insert(
          pubkey: publicKeyHex,
          username: Value(username),
          displayName: Value(displayName ?? username),
          bio: Value(about),
          avatarUrl: Value(pictureUrl),
          bannerUrl: Value(bannerUrl),
          nip05: Value(nip05),
          status: Value(status),
          statusEmoji: Value(statusEmoji),
          profileFetchedAt: Value(now),
          createdAt: now,
          updatedAt: now,
        ));
      }
    } catch (e) {
      debugPrint('[Profile] Failed to update local contact: $e');
    }
  }

  /// Republish Kind 31753 member events to all servers the user belongs to.
  /// Matches Rails: publish_member_events after profile update.
  void _republishMemberEvents({
    required String privateKeyHex,
    required String publicKeyHex,
  }) async {
    try {
      final servers = await _db.select(_db.servers).get();
      final relayConfig = RelayConfigService(_db);
      final publishService = ServerPublishService(_db, _relayPool, relayConfig);
      for (final server in servers) {
        if (server.nostrGroupId == null) continue;
        await publishService.publishMember(
          privateKeyHex: privateKeyHex,
          publicKeyHex: publicKeyHex,
          server: server,
        );
      }
      debugPrint('[Profile] Republished member events to ${servers.length} servers');
    } catch (e) {
      debugPrint('[Profile] Failed to republish member events: $e');
    }
  }

  /// Fetch a Kind 0 profile for a pubkey from relays
  Future<Map<String, dynamic>?> fetchProfile(String pubkey) async {
    final filter = NostrFilter(
      kinds: [0],
      authors: [pubkey],
      limit: 1,
    );

    final events = await _relayPool.fetch(filter, timeout: const Duration(seconds: 10));
    if (events.isEmpty) return null;

    // Use the most recent Kind 0
    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    try {
      return json.decode(events.first.content) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Publish Kind 3 contacts list
  Future<Map<String, bool>> publishContacts({
    required String privateKeyHex,
    required String publicKeyHex,
    required List<ContactEntry> contacts,
  }) async {
    final tags = contacts.map((c) => [
      'p',
      c.pubkey,
      c.relayUrl ?? '',
      c.petname ?? '',
    ]).toList();

    final event = crypto.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: crypto.NostrEvent.now(),
      kind: 3,
      tags: tags,
      content: '',
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    return _relayPool.publish(signed);
  }
}

class ContactEntry {
  final String pubkey;
  final String? relayUrl;
  final String? petname;

  ContactEntry({required this.pubkey, this.relayUrl, this.petname});
}
