import 'package:flutter/foundation.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';

/// Entry in a NIP-65 relay list (Kind 10002).
class RelayEntry {
  final String url;
  final bool read;
  final bool write;
  RelayEntry({required this.url, this.read = true, this.write = true});
}

/// Publishes and fetches the user's preferred relay list via Kind 10002
/// (NIP-65). All devices subscribing to the same pubkey see the same relay
/// configuration, keeping them in sync.
class RelaySyncService {
  final RelayPool _relayPool;

  RelaySyncService(this._relayPool);

  /// Publish a Kind 10002 relay list event.
  Future<void> publishRelayList({
    required String privateKeyHex,
    required String publicKeyHex,
    required List<RelayEntry> relays,
  }) async {
    final tags = <List<String>>[];
    for (final r in relays) {
      if (r.read && r.write) {
        tags.add(['r', r.url]);
      } else if (r.read) {
        tags.add(['r', r.url, 'read']);
      } else if (r.write) {
        tags.add(['r', r.url, 'write']);
      }
    }

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 10002,
      tags: tags,
      content: '',
    );
    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    await _relayPool.publish(signed);
    debugPrint('[RelaySyncService] Published Kind 10002 with ${relays.length} relays');
  }

  /// Fetch the latest Kind 10002 relay list for [publicKeyHex].
  Future<List<RelayEntry>> fetchRelayList(String publicKeyHex) async {
    final filter = NostrFilter(kinds: [10002], authors: [publicKeyHex], limit: 5);
    final events = await _relayPool.fetch(filter, timeout: const Duration(seconds: 8));
    if (events.isEmpty) return [];

    // Take the most recent.
    events.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final latest = events.first;

    final relays = <RelayEntry>[];
    for (final tag in latest.tags) {
      if (tag.isEmpty || tag[0] != 'r' || tag.length < 2) continue;
      final url = tag[1];
      if (tag.length >= 3) {
        final marker = tag[2].toLowerCase();
        relays.add(RelayEntry(url: url, read: marker == 'read', write: marker == 'write'));
      } else {
        relays.add(RelayEntry(url: url)); // both
      }
    }
    debugPrint('[RelaySyncService] Fetched ${relays.length} relays from Kind 10002');
    return relays;
  }
}
