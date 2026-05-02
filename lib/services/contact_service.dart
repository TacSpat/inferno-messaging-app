import 'package:drift/drift.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';
import '../crypto/nostr_event.dart' as nostr;
import 'dart:convert';

class ContactService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  ContactService(this._db, this._relayPool);

  /// Add a contact by pubkey
  Future<Contact> addContact(String pubkey, {String? petname}) async {
    final now = DateTime.now();
    final existing = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(pubkey)))
        .getSingleOrNull();
    if (existing != null) {
      await (_db.update(_db.contacts)..where((c) => c.pubkey.equals(pubkey)))
          .write(ContactsCompanion(petname: Value(petname), updatedAt: Value(now)));
    } else {
      await _db.into(_db.contacts).insert(ContactsCompanion.insert(
        pubkey: pubkey,
        petname: Value(petname),
        friendshipStatus: const Value(0), // not_friend
        createdAt: now,
        updatedAt: now,
      ));
    }

    // Fetch profile from relays
    await fetchContactProfile(pubkey);

    return (await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(pubkey)))
        .getSingle());
  }

  /// Block a contact
  Future<void> blockContact(String pubkey) async {
    await (_db.update(_db.contacts)
          ..where((c) => c.pubkey.equals(pubkey)))
        .write(ContactsCompanion(
      friendshipStatus: const Value(5), // blocked
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Unblock a contact
  Future<void> unblockContact(String pubkey) async {
    await (_db.update(_db.contacts)
          ..where((c) => c.pubkey.equals(pubkey)))
        .write(ContactsCompanion(
      friendshipStatus: const Value(0), // not_friend
      updatedAt: Value(DateTime.now()),
    ));
  }

  /// Remove a contact
  Future<void> removeContact(String pubkey) async {
    await (_db.delete(_db.contacts)
          ..where((c) => c.pubkey.equals(pubkey)))
        .go();
  }

  /// Fetch and cache a contact's profile from relays (Kind 0). If no contact
  /// row exists yet (e.g. first DM from a stranger), insert one so the fetched
  /// metadata isn't silently dropped.
  Future<void> fetchContactProfile(String pubkey) async {
    final filter = NostrFilter(kinds: [0], authors: [pubkey], limit: 1);
    final events = await _relayPool.fetch(filter, timeout: const Duration(seconds: 8));
    if (events.isEmpty) return;

    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    try {
      final profile = json.decode(events.first.content) as Map<String, dynamic>;
      final now = DateTime.now();
      final existing = await (_db.select(_db.contacts)
            ..where((c) => c.pubkey.equals(pubkey)))
          .getSingleOrNull();
      if (existing != null) {
        await (_db.update(_db.contacts)..where((c) => c.pubkey.equals(pubkey)))
            .write(ContactsCompanion(
          username: Value(profile['name'] as String?),
          displayName: Value(profile['display_name'] as String?),
          bio: Value(profile['about'] as String?),
          avatarUrl: Value(profile['picture'] as String?),
          bannerUrl: Value(profile['banner'] as String?),
          nip05: Value(profile['nip05'] as String?),
          status: Value(profile['status'] as String?),
          statusEmoji: Value(profile['status_emoji'] as String?),
          profileFetchedAt: Value(now),
          updatedAt: Value(now),
        ));
      } else {
        await _db.into(_db.contacts).insert(ContactsCompanion.insert(
          pubkey: pubkey,
          username: Value(profile['name'] as String?),
          displayName: Value(profile['display_name'] as String?),
          bio: Value(profile['about'] as String?),
          avatarUrl: Value(profile['picture'] as String?),
          bannerUrl: Value(profile['banner'] as String?),
          nip05: Value(profile['nip05'] as String?),
          status: Value(profile['status'] as String?),
          statusEmoji: Value(profile['status_emoji'] as String?),
          friendshipStatus: const Value(0),
          profileFetchedAt: Value(now),
          createdAt: now,
          updatedAt: now,
        ));
      }
    } catch (_) {}
  }

  /// Batch fetch profiles for multiple pubkeys
  Future<void> fetchProfiles(List<String> pubkeys) async {
    if (pubkeys.isEmpty) return;
    final filter = NostrFilter(kinds: [0], authors: pubkeys);
    final events = await _relayPool.fetch(filter, timeout: const Duration(seconds: 10));

    // Group by pubkey, take latest
    final byPubkey = <String, nostr.NostrEvent>{};
    for (final event in events) {
      final existing = byPubkey[event.pubkey];
      if (existing == null || event.createdAt > existing.createdAt) {
        byPubkey[event.pubkey] = event;
      }
    }

    for (final entry in byPubkey.entries) {
      try {
        final profile = json.decode(entry.value.content) as Map<String, dynamic>;
        final now = DateTime.now();
        final existing = await (_db.select(_db.contacts)
              ..where((c) => c.pubkey.equals(entry.key)))
            .getSingleOrNull();
        if (existing != null) {
          await (_db.update(_db.contacts)..where((c) => c.pubkey.equals(entry.key)))
              .write(ContactsCompanion(
            username: Value(profile['name'] as String?),
            displayName: Value(profile['display_name'] as String?),
            bio: Value(profile['about'] as String?),
            avatarUrl: Value(profile['picture'] as String?),
            bannerUrl: Value(profile['banner'] as String?),
            nip05: Value(profile['nip05'] as String?),
            status: Value(profile['status'] as String?),
            statusEmoji: Value(profile['status_emoji'] as String?),
            profileFetchedAt: Value(now),
            updatedAt: Value(now),
          ));
        } else {
          await _db.into(_db.contacts).insert(ContactsCompanion.insert(
            pubkey: entry.key,
            username: Value(profile['name'] as String?),
            displayName: Value(profile['display_name'] as String?),
            bio: Value(profile['about'] as String?),
            avatarUrl: Value(profile['picture'] as String?),
            bannerUrl: Value(profile['banner'] as String?),
            nip05: Value(profile['nip05'] as String?),
            status: Value(profile['status'] as String?),
            statusEmoji: Value(profile['status_emoji'] as String?),
            profileFetchedAt: Value(now),
            createdAt: now,
            updatedAt: now,
          ));
        }
      } catch (_) {}
    }
  }

  /// Get display name for a pubkey (from contacts table)
  Future<String> getDisplayName(String pubkey) async {
    final contact = await (_db.select(_db.contacts)
          ..where((c) => c.pubkey.equals(pubkey)))
        .getSingleOrNull();
    if (contact != null) {
      return contact.displayName ?? contact.username ?? '${pubkey.substring(0, 8)}...';
    }
    return '${pubkey.substring(0, 8)}...';
  }

  /// Watch all contacts
  Stream<List<Contact>> watchAllContacts() {
    return (_db.select(_db.contacts)
          ..orderBy([(c) => OrderingTerm.asc(c.displayName)]))
        .watch();
  }

  /// Watch friends only
  Stream<List<Contact>> watchFriends() {
    return (_db.select(_db.contacts)
          ..where((c) => c.friendshipStatus.equals(3))
          ..orderBy([(c) => OrderingTerm.asc(c.displayName)]))
        .watch();
  }

  /// Watch pending incoming
  Stream<List<Contact>> watchPendingIncoming() {
    return (_db.select(_db.contacts)
          ..where((c) => c.friendshipStatus.equals(2)))
        .watch();
  }

  /// Watch pending outgoing
  Stream<List<Contact>> watchPendingOutgoing() {
    return (_db.select(_db.contacts)
          ..where((c) => c.friendshipStatus.equals(1)))
        .watch();
  }

  /// Watch blocked
  Stream<List<Contact>> watchBlocked() {
    return (_db.select(_db.contacts)
          ..where((c) => c.friendshipStatus.equals(5)))
        .watch();
  }
}
