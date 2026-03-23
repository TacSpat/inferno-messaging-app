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

    // Fetch Kind 9 group messages + deletions + pins
    final events = await _relayPool.fetch(
      NostrFilter(
        kinds: [9, 9005, 9006],
        tags: {'#h': [channelGroupId]},
        since: sinceUnix,
      ),
      timeout: const Duration(seconds: 15),
    );

    if (events.isEmpty) return 0;

    int imported = 0;
    // Sort chronologically
    final sorted = events.toList()..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    for (final event in sorted) {
      if (event.id == null) continue;

      if (event.kind == 9) {
        // processInboundMessage handles dedup internally
        await _groupMessageService.processInboundMessage(event, privateKeyHex);
        imported++;
      } else if (event.kind == 9005) {
        final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
        if (eTag != null && eTag.length > 1) {
          await (_db.delete(_db.messages)..where((m) => m.nostrEventId.equals(eTag[1]))).go();
        }
      } else if (event.kind == 9006) {
        final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
        final pinnedTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'pinned').firstOrNull;
        if (eTag != null && eTag.length > 1) {
          final pinned = pinnedTag != null && pinnedTag.length > 1 && pinnedTag[1] == 'true';
          await (_db.update(_db.messages)..where((m) => m.nostrEventId.equals(eTag[1])))
              .write(MessagesCompanion(pinned: Value(pinned), updatedAt: Value(DateTime.now())));
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
    if (allEvents.isEmpty) return 0;

    int imported = 0;
    final sorted = allEvents.where((e) => e.id != null).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    for (final event in sorted) {
      try {
        await _dmService.processInboundDm(event, privateKeyHex, ownPubkey);
        imported++;
      } catch (_) {}
    }

    return imported;
  }
}
