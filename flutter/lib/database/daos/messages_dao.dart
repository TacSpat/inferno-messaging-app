import 'package:drift/drift.dart';
import '../database.dart';
import '../tables/messages.dart';
import '../tables/reactions.dart';
import '../tables/channel_reads.dart';
import '../tables/conversations.dart';

part 'messages_dao.g.dart';

@DriftAccessor(tables: [Messages, Reactions, ChannelReads, Conversations])
class MessagesDao extends DatabaseAccessor<InfernoDatabase>
    with _$MessagesDaoMixin {
  MessagesDao(super.db);

  // Get messages for a channel, ordered by creation time
  Future<List<Message>> getChannelMessages(int channelId, {int limit = 50, int offset = 0}) {
    return (select(messages)
          ..where((m) => m.channelId.equals(channelId))
          ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  // Watch messages for a channel (reactive)
  Stream<List<Message>> watchChannelMessages(int channelId, {int limit = 50}) {
    return (select(messages)
          ..where((m) => m.channelId.equals(channelId))
          ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
          ..limit(limit))
        .watch();
  }

  // Get messages for a conversation (DM)
  Future<List<Message>> getConversationMessages(int conversationId, {int limit = 50, int offset = 0}) {
    return (select(messages)
          ..where((m) => m.conversationId.equals(conversationId))
          ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
          ..limit(limit, offset: offset))
        .get();
  }

  // Watch messages for a conversation (reactive).
  // Filters out system DMs (voice handshakes, state sync) that were
  // stored before the ingest guard was added.
  Stream<List<Message>> watchConversationMessages(int conversationId, {int limit = 50}) {
    return (select(messages)
          ..where((m) =>
              m.conversationId.equals(conversationId) &
              m.content.like('{"type":"voice_%').not() &
              m.content.like('{"type":"friend_%').not())
          ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
          ..limit(limit))
        .watch();
  }

  // Get a single message by public ID
  Future<Message?> getByPublicId(String publicId) {
    return (select(messages)..where((m) => m.publicId.equals(publicId)))
        .getSingleOrNull();
  }

  // Get a single message by Nostr event ID
  Future<Message?> getByNostrEventId(String eventId) {
    return (select(messages)..where((m) => m.nostrEventId.equals(eventId)))
        .getSingleOrNull();
  }

  // Insert a message
  Future<int> insertMessage(MessagesCompanion message) {
    return into(messages).insert(message);
  }

  // Update a message
  Future<bool> updateMessage(MessagesCompanion message, int id) {
    return (update(messages)..where((m) => m.id.equals(id))).write(message).then((rows) => rows > 0);
  }

  // Delete a message by ID
  Future<int> deleteMessage(int id) {
    return (delete(messages)..where((m) => m.id.equals(id))).go();
  }

  // Get pinned messages for a channel
  Future<List<Message>> getPinnedMessages(int channelId) {
    return (select(messages)
          ..where((m) => m.channelId.equals(channelId) & m.pinned.equals(true))
          ..orderBy([(m) => OrderingTerm.desc(m.createdAt)]))
        .get();
  }

  // Watch pinned messages for a channel (reactive)
  Stream<List<Message>> watchPinnedMessages(int channelId) {
    return (select(messages)
          ..where((m) => m.channelId.equals(channelId) & m.pinned.equals(true))
          ..orderBy([(m) => OrderingTerm.desc(m.createdAt)]))
        .watch();
  }

  // Watch reactions for a message
  Stream<List<Reaction>> watchReactions(int messageId) {
    return (select(reactions)..where((r) => r.messageId.equals(messageId)))
        .watch();
  }

  // Count messages in a channel since a timestamp (for unread badges)
  Future<int> countMessagesSince(int channelId, DateTime since) async {
    final count = countAll();
    final query = selectOnly(messages)
      ..addColumns([count])
      ..where(messages.channelId.equals(channelId) &
          messages.createdAt.isBiggerThanValue(since));
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  // Watch unread count for a channel since lastReadAt (reactive)
  Stream<int> watchUnreadCount(int channelId, DateTime since) {
    final count = countAll();
    final query = selectOnly(messages)
      ..addColumns([count])
      ..where(messages.channelId.equals(channelId) &
          messages.createdAt.isBiggerThanValue(since));
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  // Watch whether a channel has ANY messages
  Stream<bool> watchHasMessages(int channelId) {
    final count = countAll();
    final query = selectOnly(messages)
      ..addColumns([count])
      ..where(messages.channelId.equals(channelId));
    return query.watchSingle().map((row) => (row.read(count) ?? 0) > 0);
  }

  // Watch unread count for a DM conversation since lastReadAt
  Stream<int> watchConversationUnreadCount(int conversationId, DateTime since) {
    final count = countAll();
    final query = selectOnly(messages)
      ..addColumns([count])
      ..where(messages.conversationId.equals(conversationId) &
          messages.createdAt.isBiggerThanValue(since) &
          messages.content.like('{"type":"voice_%').not() &
          messages.content.like('{"type":"friend_%').not());
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  // Watch whether a conversation has ANY visible messages
  Stream<bool> watchConversationHasMessages(int conversationId) {
    final count = countAll();
    final query = selectOnly(messages)
      ..addColumns([count])
      ..where(messages.conversationId.equals(conversationId) &
          messages.content.like('{"type":"voice_%').not() &
          messages.content.like('{"type":"friend_%').not());
    return query.watchSingle().map((row) => (row.read(count) ?? 0) > 0);
  }

  // Upsert channel read timestamp
  Future<void> upsertChannelRead(int channelId, int userId) async {
    final now = DateTime.now();
    final existing = await (select(channelReads)
          ..where((r) => r.channelId.equals(channelId) & r.userId.equals(userId)))
        .getSingleOrNull();
    if (existing != null) {
      await (update(channelReads)..where((r) => r.id.equals(existing.id)))
          .write(ChannelReadsCompanion(lastReadAt: Value(now), updatedAt: Value(now)));
    } else {
      await into(channelReads).insert(ChannelReadsCompanion.insert(
        channelId: channelId,
        userId: userId,
        lastReadAt: now,
        createdAt: now,
        updatedAt: now,
      ));
    }
  }

  // Watch all channel reads for a user
  Stream<List<ChannelRead>> watchChannelReads(int userId) {
    return (select(channelReads)..where((r) => r.userId.equals(userId))).watch();
  }

  // Watch a single channel's read timestamp
  Stream<ChannelRead?> watchChannelRead(int channelId, int userId) {
    return (select(channelReads)
          ..where((r) => r.channelId.equals(channelId) & r.userId.equals(userId)))
        .watchSingleOrNull();
  }

  // Mark a conversation as read
  Future<void> markConversationRead(int conversationId) async {
    await (update(conversations)..where((c) => c.id.equals(conversationId)))
        .write(ConversationsCompanion(
      lastReadAt: Value(DateTime.now()),
      updatedAt: Value(DateTime.now()),
    ));
  }
}
