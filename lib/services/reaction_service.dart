import 'package:drift/drift.dart';
import '../crypto/nostr_event.dart' as nostr;
import '../crypto/nostr_signer.dart';
import '../database/database.dart';
import '../nostr/relay_pool.dart';

class ReactionService {
  final InfernoDatabase _db;
  final RelayPool _relayPool;

  ReactionService(this._db, this._relayPool);

  /// Add a reaction to a message
  Future<void> addReaction({
    required String privateKeyHex,
    required String publicKeyHex,
    required Message message,
    required String emoji,
    String? channelGroupId,
  }) async {
    // Store locally
    final now = DateTime.now();
    await _db.into(_db.reactions).insert(ReactionsCompanion.insert(
      messageId: message.id,
      userId: 0, // local user
      emoji: Value(emoji),
      createdAt: now,
      updatedAt: now,
    ));

    // Publish Kind 7 event
    if (message.nostrEventId == null) return;
    final tags = <List<String>>[
      ['e', message.nostrEventId!],
      ['p', message.nostrAuthorPubkey ?? publicKeyHex],
    ];
    if (channelGroupId != null) {
      tags.add(['h', channelGroupId]);
    }

    final event = nostr.NostrEvent(
      pubkey: publicKeyHex,
      createdAt: nostr.NostrEvent.now(),
      kind: 7,
      tags: tags,
      content: emoji,
    );

    final signer = NostrSigner(privateKeyHex: privateKeyHex);
    final signed = signer.sign(event);
    _relayPool.publish(signed);
  }

  /// Toggle a reaction by event ID (add if not present, remove if present)
  Future<void> toggleReaction({
    required String privateKeyHex,
    required String publicKeyHex,
    required String eventId,
    required String emoji,
  }) async {
    final message = await (_db.select(_db.messages)
          ..where((m) => m.nostrEventId.equals(eventId)))
        .getSingleOrNull();
    if (message == null) return;

    // Check if already reacted
    final existing = await (_db.select(_db.reactions)
          ..where((r) => r.messageId.equals(message.id) & r.emoji.equals(emoji) & r.userId.equals(0)))
        .getSingleOrNull();
    if (existing != null) {
      await removeReaction(message.id, emoji);
    } else {
      await addReaction(
        privateKeyHex: privateKeyHex,
        publicKeyHex: publicKeyHex,
        message: message,
        emoji: emoji,
      );
    }
  }

  /// Remove a reaction
  Future<void> removeReaction(int messageId, String emoji) async {
    await (_db.delete(_db.reactions)
          ..where((r) => r.messageId.equals(messageId) & r.emoji.equals(emoji) & r.userId.equals(0)))
        .go();
  }

  /// Process inbound Kind 7 reaction
  Future<void> processInboundReaction(nostr.NostrEvent event) async {
    final eTag = event.tags.where((t) => t.isNotEmpty && t[0] == 'e').firstOrNull;
    if (eTag == null || eTag.length < 2) return;

    final message = await (_db.select(_db.messages)
          ..where((m) => m.nostrEventId.equals(eTag[1])))
        .getSingleOrNull();
    if (message == null) return;

    final now = DateTime.now();
    try {
      await _db.into(_db.reactions).insert(ReactionsCompanion.insert(
        messageId: message.id,
        userId: 0, // will be resolved to contact later
        emoji: Value(event.content.isNotEmpty ? event.content : '+'),
        createdAt: now,
        updatedAt: now,
      ));
    } catch (_) {} // Ignore duplicates
  }

  /// Watch reactions for a message
  Stream<List<Reaction>> watchReactions(int messageId) {
    return (_db.select(_db.reactions)
          ..where((r) => r.messageId.equals(messageId)))
        .watch();
  }

  /// Get grouped reaction counts for a message
  Future<Map<String, int>> getReactionCounts(int messageId) async {
    final reactions = await (_db.select(_db.reactions)
          ..where((r) => r.messageId.equals(messageId)))
        .get();
    final counts = <String, int>{};
    for (final r in reactions) {
      final emoji = r.emoji ?? '+';
      counts[emoji] = (counts[emoji] ?? 0) + 1;
    }
    return counts;
  }
}
