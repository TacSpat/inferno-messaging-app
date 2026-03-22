import 'dart:convert';
import '../crypto/nostr_event.dart';
import '../crypto/nostr_signer.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';

class NostrProfileService {
  final RelayPool _relayPool;

  NostrProfileService(this._relayPool);

  /// Publish a Kind 0 profile metadata event
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

    final event = NostrEvent(
      pubkey: publicKeyHex,
      createdAt: NostrEvent.now(),
      kind: 0,
      tags: [],
      content: json.encode(profileData),
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    return _relayPool.publish(signed);
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

    final event = NostrEvent(
      pubkey: publicKeyHex,
      createdAt: NostrEvent.now(),
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
