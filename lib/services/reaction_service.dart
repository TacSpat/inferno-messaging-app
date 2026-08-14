import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';
import 'dm_service.dart';

class ReactionService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  ReactionService(this._db, this._relayPool);

  /// Max distinct emojis per message. Stacking on an existing reaction is
  /// always allowed; only *new* emojis past this cap are rejected so a
  /// message can't accumulate an unbounded reaction rail.
  static const int maxDistinctReactionsPerMessage = 15;

  /// Returned by [addReaction] / [toggleReaction] so callers can show a
  /// toast when the limit is hit.
  bool _lastAddWasBlocked = false;
  bool get lastAddWasBlocked => _lastAddWasBlocked;

  /// Add a reaction to a message and publish Kind 7 to Nostr.
  /// Returns true if the reaction was accepted, false if the cap was hit.
  Future<bool> addReaction({
    required String privateKeyHex,
    required String publicKeyHex,
    required Message message,
    required String emoji,
    String? channelGroupId,
  }) async {
    _lastAddWasBlocked = false;

    // Enforce the distinct-emoji cap. Stacking on an existing emoji is fine;
    // adding a new emoji past the cap is rejected.
    final existingEmojis = await (_db.selectOnly(_db.reactions, distinct: true)
          ..addColumns([_db.reactions.emoji])
          ..where(_db.reactions.messageId.equals(message.id) &
              _db.reactions.emoji.isNotNull()))
        .map((row) => row.read(_db.reactions.emoji))
        .get();
    final distinctCount = existingEmojis.whereType<String>().toSet();
    if (!distinctCount.contains(emoji) &&
        distinctCount.length >= maxDistinctReactionsPerMessage) {
      _lastAddWasBlocked = true;
      return false;
    }

    // Store locally with reactor pubkey
    final now = DateTime.now();
    try {
      await _db.into(_db.reactions).insert(ReactionsCompanion.insert(
        messageId: message.id,
        userId: 0,
        emoji: Value(emoji),
        reactorPubkey: Value(publicKeyHex),
        createdAt: now,
        updatedAt: now,
      ));
    } catch (_) {} // Ignore duplicate

    // Publish Kind 7 event
    _publishKind7(
      privateKeyHex: privateKeyHex,
      publicKeyHex: publicKeyHex,
      message: message,
      content: emoji,
      emoji: emoji,
      channelGroupId: channelGroupId,
    );
    return true;
  }

  /// Toggle a reaction (add if not present, remove if present)
  Future<void> toggleReaction({
    required String privateKeyHex,
    required String publicKeyHex,
    required String eventId,
    required String emoji,
    String? channelGroupId,
  }) async {
    final message = await (_db.select(_db.messages)
          ..where((m) => m.nostrEventId.equals(eventId)))
        .getSingleOrNull();
    if (message == null) return;

    // Check if already reacted by our pubkey
    final existing = await (_db.select(_db.reactions)
          ..where((r) => r.messageId.equals(message.id) &
              r.emoji.equals(emoji) &
              r.reactorPubkey.equals(publicKeyHex)))
        .getSingleOrNull();

    if (existing != null) {
      await removeReaction(
        privateKeyHex: privateKeyHex,
        publicKeyHex: publicKeyHex,
        message: message,
        emoji: emoji,
        channelGroupId: channelGroupId,
      );
    } else {
      await addReaction(
        privateKeyHex: privateKeyHex,
        publicKeyHex: publicKeyHex,
        message: message,
        emoji: emoji,
        channelGroupId: channelGroupId,
      );
    }
  }

  /// Remove a reaction locally and publish Kind 7 with "-" content
  Future<void> removeReaction({
    required String privateKeyHex,
    required String publicKeyHex,
    required Message message,
    required String emoji,
    String? channelGroupId,
  }) async {
    // Delete locally
    await (_db.delete(_db.reactions)
          ..where((r) => r.messageId.equals(message.id) &
              r.emoji.equals(emoji) &
              r.reactorPubkey.equals(publicKeyHex)))
        .go();

    // Publish Kind 7 removal (content = "-")
    _publishKind7(
      privateKeyHex: privateKeyHex,
      publicKeyHex: publicKeyHex,
      message: message,
      content: '-',
      emoji: emoji,
      channelGroupId: channelGroupId,
    );
  }

  /// Publish a Kind 7 Nostr event (reaction add or removal)
  /// [content] is the emoji for an add, or "-" for a removal (NIP-25).
  /// [emoji] always carries the actual emoji, which the encrypted DM path
  /// needs on removal since "-" does not identify what to remove.
  Future<void> _publishKind7({
    required String privateKeyHex,
    required String publicKeyHex,
    required Message message,
    required String content,
    required String emoji,
    String? channelGroupId,
  }) async {
    if (message.nostrEventId == null) {
      debugPrint('[ReactionService] Cannot publish Kind 7: message has no nostrEventId');
      return;
    }

    // Reactions on a DM go out encrypted, never as a public Kind 7. A public
    // reaction carries an `e` tag naming the DM's event ID and a `p` tag
    // naming the counterparty, which leaks who is talking to whom and which
    // message was reacted to — the message body being encrypted does not help.
    if (message.conversationId != null) {
      final conversation = await (_db.select(_db.conversations)
            ..where((c) => c.id.equals(message.conversationId!)))
          .getSingleOrNull();
      final counterparty = conversation?.counterpartyPubkey;
      if (counterparty == null) {
        // Group DM: no single counterparty, and there is no encrypted
        // group-reaction path yet. Keep it local rather than leak it.
        debugPrint('[ReactionService] Group DM reaction kept local (no encrypted fan-out yet)');
        return;
      }
      await DmService(_db, _relayPool).sendReaction(
        privateKeyHex: privateKeyHex,
        publicKeyHex: publicKeyHex,
        recipientPubkey: counterparty,
        targetEventId: message.nostrEventId!,
        emoji: emoji,
        action: content == '-' ? 'remove' : 'add',
      );
      return;
    }

    final tags = <List<String>>[
      ['e', message.nostrEventId!],
      ['p', message.nostrAuthorPubkey ?? publicKeyHex],
      ['k', '9'],
    ];
    if (channelGroupId != null) {
      tags.add(['h', channelGroupId]);
    } else {
      debugPrint('[ReactionService] WARNING: no channelGroupId — h tag omitted, Rails will not see this reaction');
    }

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 7,
      tags: tags,
      content: content,
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    debugPrint('[ReactionService] Publishing Kind 7: content="$content" tags=$tags eventId=${signed.id}');

    // Log outbound event for dedup
    _logEvent(signed.id!, signed.pubkey, signed.createdAt, 'outbound');

    final results = await _relayPool.publish(signed);
    for (final entry in results.entries) {
      debugPrint('[ReactionService] Relay ${entry.key}: ${entry.value ? "OK" : "FAILED"}');
    }
  }

  /// Process inbound Kind 7 reaction from relays
  Future<void> processInboundReaction(nostr.NostrEvent event) async {
    // Dedup: skip if we already processed this event ID
    if (event.id != null) {
      final alreadySeen = await (_db.select(_db.nostrEventLogs)
            ..where((l) => l.eventId.equals(event.id!)))
          .getSingleOrNull();
      if (alreadySeen != null) return;
    }

    final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
    if (eTag == null || eTag.length < 2) return;

    final message = await (_db.select(_db.messages)
          ..where((m) => m.nostrEventId.equals(eTag[1])))
        .getSingleOrNull();
    if (message == null) return;

    final emoji = event.content;
    final reactorPubkey = event.pubkey;

    // Handle removal: content == "-"
    if (emoji == '-') {
      await (_db.delete(_db.reactions)
            ..where((r) => r.messageId.equals(message.id) &
                r.reactorPubkey.equals(reactorPubkey)))
          .go();
      // Log this event so we know it was processed
      if (event.id != null) _logEvent(event.id!, reactorPubkey, event.createdAt, 'inbound');
      return;
    }

    if (emoji.isEmpty) return;

    // Check if a newer removal event exists for this reactor+message
    // (handles out-of-order delivery: add arrives after remove)
    if (event.id != null) {
      final eventTime = DateTime.fromMillisecondsSinceEpoch(event.createdAt * 1000);
      // Look for any logged removal (Kind 7, same pubkey) that's newer
      final newerRemoval = await (_db.select(_db.nostrEventLogs)
            ..where((l) => l.kind.equals(7) &
                l.pubkey.equals(reactorPubkey) &
                l.messageId.equals(message.id) &
                l.eventCreatedAt.isBiggerThanValue(eventTime)))
          .getSingleOrNull();
      if (newerRemoval != null) {
        debugPrint('[ReactionService] Skipping stale add event (newer removal exists)');
        _logEvent(event.id!, reactorPubkey, event.createdAt, 'inbound');
        return;
      }
    }

    // Enforce the per-message distinct-emoji cap locally too, so a remote
    // reactor can't spam our UI beyond the limit even if the relay accepted
    // the event.
    final existingEmojis = await (_db.selectOnly(_db.reactions, distinct: true)
          ..addColumns([_db.reactions.emoji])
          ..where(_db.reactions.messageId.equals(message.id) &
              _db.reactions.emoji.isNotNull()))
        .map((row) => row.read(_db.reactions.emoji))
        .get();
    final distinct = existingEmojis.whereType<String>().toSet();
    if (!distinct.contains(emoji) &&
        distinct.length >= maxDistinctReactionsPerMessage) {
      // Cap hit — don't store it, but still log so we don't re-process.
      if (event.id != null) _logEvent(event.id!, reactorPubkey, event.createdAt, 'inbound', messageId: message.id);
      return;
    }

    // Insert reaction (ignore duplicate)
    final now = DateTime.now();
    try {
      await _db.into(_db.reactions).insert(ReactionsCompanion.insert(
        messageId: message.id,
        userId: 0,
        emoji: Value(emoji),
        reactorPubkey: Value(reactorPubkey),
        createdAt: now,
        updatedAt: now,
      ));
    } catch (_) {} // Unique constraint handles dedup

    // Log this event
    if (event.id != null) _logEvent(event.id!, reactorPubkey, event.createdAt, 'inbound', messageId: message.id);
  }

  /// Log a Kind 7 event to prevent re-processing
  void _logEvent(String eventId, String pubkey, int createdAt, String direction, {int? messageId}) {
    final eventTime = DateTime.fromMillisecondsSinceEpoch(createdAt * 1000);
    final now = DateTime.now();
    try {
      _db.into(_db.nostrEventLogs).insert(NostrEventLogsCompanion.insert(
        eventId: eventId,
        kind: 7,
        pubkey: pubkey,
        direction: direction,
        messageId: Value(messageId),
        eventCreatedAt: Value(eventTime),
        createdAt: now,
        updatedAt: now,
      ));
    } catch (_) {} // Ignore duplicate event IDs
  }

  /// Watch reactions for a message
  Stream<List<Reaction>> watchReactions(int messageId) {
    return (_db.select(_db.reactions)
          ..where((r) => r.messageId.equals(messageId)))
        .watch();
  }
}
