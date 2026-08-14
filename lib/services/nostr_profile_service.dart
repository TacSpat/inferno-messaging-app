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
    // Kind 0 is replaceable: the published content object replaces the
    // previous one wholesale. Building it from only the fields passed in
    // therefore DELETED every field the caller omitted — the profile screen
    // never passes nip05, so every save silently dropped it, and a device
    // with a stale cache would wipe whatever another device had set.
    //
    // Start from the currently published profile and overlay onto it.
    // Anything we do not manage (including fields from NIPs this client does
    // not know about) survives untouched.
    final profileData = <String, dynamic>{};
    try {
      final existing = await _relayPool.fetch(
        NostrFilter(kinds: [0], authors: [publicKeyHex], limit: 1),
        timeout: const Duration(seconds: 5),
      );
      if (existing.isNotEmpty) {
        final decoded = json.decode(existing.first.content);
        if (decoded is Map<String, dynamic>) profileData.addAll(decoded);
      }
    } catch (e) {
      // Fall through to a fresh object. Publishing the fields we do have beats
      // failing the save outright, but log it — this is the path where a
      // partial profile can still overwrite a richer one.
      debugPrint('[Profile] Could not read existing profile to merge: $e');
    }

    /// null  -> leave whatever is already published untouched
    /// ''    -> the user cleared this field, so remove it
    /// value -> set it
    void apply(String key, String? value) {
      if (value == null) return;
      if (value.isEmpty) {
        profileData.remove(key);
      } else {
        profileData[key] = value;
      }
    }

    profileData['name'] = username;
    apply('display_name', displayName);
    apply('about', about);
    apply('picture', pictureUrl);
    apply('banner', bannerUrl);
    apply('nip05', nip05);
    apply('status', status);
    apply('status_emoji', statusEmoji);

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
      // Also update remote_members so member list reflects changes immediately
      await (_db.update(_db.remoteMembers)
            ..where((m) => m.pubkey.equals(publicKeyHex)))
          .write(RemoteMembersCompanion(
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
      for (int i = 0; i < servers.length; i++) {
        final server = servers[i];
        if (server.nostrGroupId == null) continue;
        if (i > 0) await Future.delayed(const Duration(seconds: 2));
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
