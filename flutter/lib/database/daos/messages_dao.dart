import 'package:drift/drift.dart';
import '../database.dart';
import '../tables/messages.dart';
import '../tables/reactions.dart';

part 'messages_dao.g.dart';

@DriftAccessor(tables: [Messages, Reactions])
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

  // Watch messages for a conversation (reactive)
  Stream<List<Message>> watchConversationMessages(int conversationId, {int limit = 50}) {
    return (select(messages)
          ..where((m) => m.conversationId.equals(conversationId))
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
}
