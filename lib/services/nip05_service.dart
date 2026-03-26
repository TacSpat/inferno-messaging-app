import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import '../database/database.dart';

/// NIP-05 identity verification service.
/// Resolves user@domain identifiers to Nostr pubkeys via .well-known/nostr.json
class Nip05Service {
  final InfernoDatabase _db;

  // In-memory cache to avoid repeated HTTP requests (24h TTL)
  final Map<String, _Nip05CacheEntry> _cache = {};

  Nip05Service(this._db);

  /// Verify a NIP-05 identifier (user@domain) against a pubkey.
  /// Returns true if the .well-known/nostr.json resolves to the given pubkey.
  Future<bool> verify(String nip05, String expectedPubkey) async {
    final resolved = await resolve(nip05);
    return resolved == expectedPubkey;
  }

  /// Resolve a NIP-05 identifier to a hex pubkey.
  /// Returns null if resolution fails.
  Future<String?> resolve(String nip05) async {
    if (!nip05.contains('@')) return null;

    final parts = nip05.split('@');
    if (parts.length != 2) return null;
    final name = parts[0];
    final domain = parts[1];

    // Check in-memory cache
    final cacheKey = '$name@$domain';
    final cached = _cache[cacheKey];
    if (cached != null && DateTime.now().difference(cached.fetchedAt).inHours < 24) {
      return cached.pubkey;
    }

    // Fetch from domain
    try {
      final url = 'https://$domain/.well-known/nostr.json?name=$name';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;

      final data = json.decode(response.body) as Map<String, dynamic>;
      final names = data['names'] as Map<String, dynamic>?;
      if (names == null) return null;

      final pubkey = names[name] as String?;
      if (pubkey != null) {
        // Cache the result
        _cache[cacheKey] = _Nip05CacheEntry(pubkey: pubkey, fetchedAt: DateTime.now());

        // Persist to contacts table
        await (_db.update(_db.contacts)..where((c) => c.pubkey.equals(pubkey)))
            .write(ContactsCompanion(nip05: Value(nip05), updatedAt: Value(DateTime.now())));
      }

      return pubkey;
    } catch (_) {
      return null;
    }
  }

  /// Batch verify NIP-05 identifiers for a list of contacts
  Future<void> verifyContacts(List<Contact> contacts) async {
    for (final contact in contacts) {
      if (contact.nip05 == null || contact.nip05!.isEmpty) continue;
      // Only re-verify if not recently checked
      if (contact.profileFetchedAt != null &&
          DateTime.now().difference(contact.profileFetchedAt!).inHours < 24) continue;

      await verify(contact.nip05!, contact.pubkey);
    }
  }
}

class _Nip05CacheEntry {
  final String pubkey;
  final DateTime fetchedAt;
  _Nip05CacheEntry({required this.pubkey, required this.fetchedAt});
}
