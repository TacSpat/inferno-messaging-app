import 'package:drift/drift.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';
import 'group_message_service.dart';
import 'dm_service.dart';

class BackfillService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;
  final GroupMessageService _groupMessageService;
  final DmService _dmService;

  BackfillService(this._db, this._relayPool, this._groupMessageService, this._dmService);

  /// Backfill channel messages from relays
  Future<int> backfillChannel({
    required String channelGroupId,
    required int backfillDays,
    String? privateKeyHex,
  }) async {
    final since = DateTime.now().subtract(Duration(days: backfillDays));
    final sinceUnix = since.millisecondsSinceEpoch ~/ 1000;

    // Fetch Kind 9 group messages
    final events = await _relayPool.fetch(
      NostrFilter(
        kinds: [9, 9005, 9006],
        tags: {'#h': [channelGroupId]},
        since: sinceUnix,
      ),
      timeout: const Duration(seconds: 15),
    );

    // Filter out already-processed events
    final eventIds = events.map((e) => e.id!).toList();
    final processed = await _db.customSelect(
      'SELECT event_id FROM nostr_event_logs WHERE event_id IN (${List.filled(eventIds.length, '?').join(',')})',
      variables: eventIds.map((id) => Variable.withString(id)).toList(),
    ).get();
    final processedIds = processed.map((r) => r.data['event_id'] as String).toSet();

    int imported = 0;
    // Sort by created_at for chronological processing
    final newEvents = events.where((e) => !processedIds.contains(e.id)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    for (final event in newEvents) {
      if (event.kind == 9) {
        await _groupMessageService.processInboundMessage(event, privateKeyHex);
        imported++;
      } else if (event.kind == 9005) {
        // Process deletion
        final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
        if (eTag != null && eTag.length > 1) {
          await (_db.delete(_db.messages)..where((m) => m.nostrEventId.equals(eTag[1]))).go();
        }
      }
    }

    return imported;
  }

  /// Backfill DM conversation from relays
  Future<int> backfillConversation({
    required String ownPubkey,
    required String counterpartyPubkey,
    required int backfillDays,
    required String privateKeyHex,
  }) async {
    final since = DateTime.now().subtract(Duration(days: backfillDays));
    final sinceUnix = since.millisecondsSinceEpoch ~/ 1000;

    // Fetch inbound DMs
    final inbound = await _relayPool.fetch(
      NostrFilter(
        kinds: [14, 1059],
        tags: {'#p': [ownPubkey]},
        authors: [counterpartyPubkey],
        since: sinceUnix,
      ),
      timeout: const Duration(seconds: 15),
    );

    // Fetch own outbound DMs to this counterparty
    final outbound = await _relayPool.fetch(
      NostrFilter(
        kinds: [14, 1059],
        authors: [ownPubkey],
        since: sinceUnix,
      ),
      timeout: const Duration(seconds: 15),
    );
    // Filter outbound to only those addressed to counterparty
    final outboundFiltered = outbound.where((e) {
      final pTag = e.tags.where((t) => t.isNotEmpty && t[0] == 'p').firstOrNull;
      return pTag != null && pTag.length > 1 && pTag[1] == counterpartyPubkey;
    });

    final allEvents = [...inbound, ...outboundFiltered];

    // Deduplicate
    final eventIds = allEvents.where((e) => e.id != null).map((e) => e.id!).toList();
    if (eventIds.isEmpty) return 0;

    final processed = await _db.customSelect(
      'SELECT event_id FROM nostr_event_logs WHERE event_id IN (${List.filled(eventIds.length, '?').join(',')})',
      variables: eventIds.map((id) => Variable.withString(id)).toList(),
    ).get();
    final processedIds = processed.map((r) => r.data['event_id'] as String).toSet();

    int imported = 0;
    final newEvents = allEvents.where((e) => e.id != null && !processedIds.contains(e.id)).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    for (final event in newEvents) {
      await _dmService.processInboundDm(event, privateKeyHex, ownPubkey);
      imported++;
    }

    return imported;
  }
}
