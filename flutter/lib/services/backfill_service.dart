import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_key.dart';
import '../crypto/nip44_crypto.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import '../nostr/nostr_filter.dart';
import 'content_safety_service.dart';
import 'group_message_service.dart';
import 'dm_service.dart';

class BackfillService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;
  final GroupMessageService _groupMessageService;
  final DmService _dmService;
  final ContentSafetyService? _contentSafety;

  BackfillService(this._db, this._relayPool, this._groupMessageService, this._dmService, [this._contentSafety]);

  /// Backfill channel messages from relays.
  /// Fetches all events, diffs against existing DB state, and applies only new/changed data
  /// in a single batch transaction (UI stream fires once, not per-row).
  Future<int> backfillChannel({
    required String channelGroupId,
    required int backfillDays,
    String? privateKeyHex,
  }) async {
    final since = DateTime.now().subtract(Duration(days: backfillDays));
    final sinceUnix = since.millisecondsSinceEpoch ~/ 1000;

    final events = await _relayPool.fetchFresh(
      NostrFilter(
        kinds: [9, 9005, 9006],
        tags: {'#h': [channelGroupId]},
        since: sinceUnix,
      ),
      timeout: const Duration(seconds: 15),
    );

    if (events.isEmpty) return 0;

    // Get the channel for this group ID
    final channel = await (_db.select(_db.channels)
          ..where((c) => c.nostrGroupId.equals(channelGroupId)))
        .getSingleOrNull();
    if (channel == null) return 0;

    // Get all existing event IDs for this channel to diff against
    final existingMessages = await (_db.select(_db.messages)
          ..where((m) => m.channelId.equals(channel.id)))
        .get();
    final existingEventIds = <String>{};
    final existingByEventId = <String, Message>{};
    for (final m in existingMessages) {
      if (m.nostrEventId != null) {
        existingEventIds.add(m.nostrEventId!);
        existingByEventId[m.nostrEventId!] = m;
      }
    }

    // Sort chronologically and compute final state
    final sorted = events.where((e) => e.id != null).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    // Separate into message creates, edits, deletes, pins
    final newMessages = <nostr.NostrEvent>[];
    final deletedEventIds = <String>{};
    final edits = <String, nostr.NostrEvent>{}; // originalEventId -> edit event
    final pins = <String, bool>{}; // eventId -> pinned state

    for (final event in sorted) {
      if (event.kind == 9) {
        // Check for edit tag
        final editTag = event.tags.where((t) =>
            t.length >= 4 && t[0] == 'e' && t[3] == 'edit').firstOrNull;
        if (editTag != null && editTag.length >= 2) {
          edits[editTag[1]] = event;
        } else if (!existingEventIds.contains(event.id)) {
          newMessages.add(event);
        }
      } else if (event.kind == 9005) {
        final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
        if (eTag != null && eTag.length > 1) {
          deletedEventIds.add(eTag[1]);
        }
      } else if (event.kind == 9006) {
        final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
        final pinnedTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'pinned').firstOrNull;
        if (eTag != null && eTag.length > 1) {
          pins[eTag[1]] = pinnedTag != null && pinnedTag.length > 1 && pinnedTag[1] == 'true';
        }
      }
    }

    // Remove messages that were both created and deleted in the same backfill
    newMessages.removeWhere((e) => deletedEventIds.contains(e.id));

    // Check if there's actually anything to do
    final hasNewMessages = newMessages.isNotEmpty;
    final hasDeletes = deletedEventIds.any((id) => existingEventIds.contains(id));
    final hasEdits = edits.keys.any((id) => existingEventIds.contains(id));
    final hasPinChanges = pins.entries.any((e) {
      final msg = existingByEventId[e.key];
      return msg != null && (msg.pinned ?? false) != e.value;
    });

    if (!hasNewMessages && !hasDeletes && !hasEdits && !hasPinChanges) {
      debugPrint('[Backfill] Channel $channelGroupId: ${events.length} events, nothing new');
      return 0;
    }

    debugPrint('[Backfill] Channel $channelGroupId: ${newMessages.length} new, ${deletedEventIds.length} deletes, ${edits.length} edits, ${pins.length} pins');

    // Apply everything in a single batch transaction (UI stream fires once)
    await _db.batch((batch) {
      // Insert new messages
      for (final event in newMessages) {
        String content = event.content;

        // Handle encrypted channels
        if (channel.encrypted && channel.channelPublicKey != null && privateKeyHex != null) {
          try {
            final convKey = Nip44Crypto.conversationKey(privateKeyHex, channel.channelPublicKey!);
            content = Nip44Crypto.decrypt(event.content, convKey);
          } catch (_) {
            continue;
          }
        }

        final publicId = NostrKey.bytesToHex(NostrKey.hexToBytes(event.id!).sublist(0, 6));
        final eventTime = DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000, isUtc: true);

        // Check for reply
        final replyTag = event.tags.where((t) =>
            t.length >= 4 && t[0] == 'e' && t[3] == 'reply').firstOrNull;
        final spoilerTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'spoiler').firstOrNull;

        batch.insert(_db.messages, MessagesCompanion.insert(
          publicId: publicId,
          content: Value(content),
          channelId: Value(channel.id),
          spoiler: Value(spoilerTag != null),
          nostrAuthorPubkey: Value(event.pubkey),
          nostrEventId: Value(event.id),
          nostrEventJson: Value(json.encode(event.toJson())),
          createdAt: eventTime,
          updatedAt: DateTime.now(),
        ), onConflict: DoNothing());
      }

      // Delete removed messages
      for (final eventId in deletedEventIds) {
        if (existingEventIds.contains(eventId)) {
          batch.deleteWhere(_db.messages, (m) => m.nostrEventId.equals(eventId));
        }
      }

      // Apply edits
      for (final entry in edits.entries) {
        if (existingEventIds.contains(entry.key)) {
          batch.update(_db.messages,
            MessagesCompanion(
              content: Value(entry.value.content),
              editedAt: Value(DateTime.fromMillisecondsSinceEpoch(entry.value.createdAt * 1000, isUtc: true)),
              updatedAt: Value(DateTime.now()),
            ),
            where: (m) => m.nostrEventId.equals(entry.key),
          );
        }
      }

      // Apply pin state changes
      for (final entry in pins.entries) {
        final existing = existingByEventId[entry.key];
        if (existing != null && (existing.pinned ?? false) != entry.value) {
          batch.update(_db.messages,
            MessagesCompanion(pinned: Value(entry.value), updatedAt: Value(DateTime.now())),
            where: (m) => m.nostrEventId.equals(entry.key),
          );
        }
      }
    });

    // Run content safety checks on newly backfilled messages (fire-and-forget)
    if (_contentSafety != null && newMessages.isNotEmpty) {
      () async {
        for (final event in newMessages) {
          if (event.id == null) continue;
          try {
            final msg = await (_db.select(_db.messages)
                  ..where((m) => m.nostrEventId.equals(event.id!)))
                .getSingleOrNull();
            if (msg != null) await _contentSafety!.check(msg.id);
          } catch (e) {
            debugPrint('[Backfill] Safety check failed for ${event.id}: $e');
          }
        }
      }();
    }

    return newMessages.length;
  }

  /// Backfill DM conversation from relays.
  /// Same approach: fetch, diff, batch apply only changes.
  Future<int> backfillConversation({
    required String ownPubkey,
    required String counterpartyPubkey,
    required int backfillDays,
    required String privateKeyHex,
  }) async {
    final since = DateTime.now().subtract(Duration(days: backfillDays));
    final sinceUnix = since.millisecondsSinceEpoch ~/ 1000;

    final inbound = await _relayPool.fetchFresh(
      NostrFilter(
        kinds: [14, 1059],
        tags: {'#p': [ownPubkey]},
        authors: [counterpartyPubkey],
        since: sinceUnix,
      ),
      timeout: const Duration(seconds: 15),
    );

    final outbound = await _relayPool.fetchFresh(
      NostrFilter(
        kinds: [14, 1059],
        authors: [ownPubkey],
        since: sinceUnix,
      ),
      timeout: const Duration(seconds: 15),
    );

    final outboundFiltered = outbound.where((e) {
      final pTag = e.tags.where((t) => t.isNotEmpty && t[0] == 'p').firstOrNull;
      return pTag != null && pTag.length > 1 && pTag[1] == counterpartyPubkey;
    });

    final allEvents = [...inbound, ...outboundFiltered];
    if (allEvents.isEmpty) return 0;

    // Get existing DM event IDs
    final existingMessages = await (_db.select(_db.messages)
          ..where((m) => m.nostrEventId.isNotNull()))
        .get();
    final existingEventIds = existingMessages
        .where((m) => m.nostrEventId != null)
        .map((m) => m.nostrEventId!)
        .toSet();

    // Filter to only new events
    final newEvents = allEvents
        .where((e) => e.id != null && !existingEventIds.contains(e.id))
        .toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    if (newEvents.isEmpty) {
      debugPrint('[Backfill] DM $counterpartyPubkey: ${allEvents.length} events, nothing new');
      return 0;
    }

    debugPrint('[Backfill] DM $counterpartyPubkey: ${newEvents.length} new of ${allEvents.length} total');

    // Process new DMs (these go through decrypt + conversation creation, harder to batch)
    // But we can at least skip already-processed events
    int imported = 0;
    for (final event in newEvents) {
      try {
        await _dmService.processInboundDm(event, privateKeyHex, ownPubkey);
        imported++;
        // Run safety check on newly imported DM
        if (_contentSafety != null && event.id != null) {
          final msg = await (_db.select(_db.messages)
                ..where((m) => m.nostrEventId.equals(event.id!)))
              .getSingleOrNull();
          if (msg != null) await _contentSafety!.check(msg.id);
        }
      } catch (_) {}
    }

    return imported;
  }
}
