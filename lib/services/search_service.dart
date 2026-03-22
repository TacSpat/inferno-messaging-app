import 'package:drift/drift.dart';
import '../database/database.dart';

class SearchService {
  final InfernoDatabase _db;

  SearchService(this._db);

  /// Search messages by content using SQL LIKE
  Future<List<Message>> searchMessages(String query, {int limit = 50, int? channelId, int? conversationId}) async {
    if (query.trim().isEmpty) return [];

    final pattern = '%${_escapeLike(query)}%';

    final q = _db.select(_db.messages)
      ..where((m) => m.content.contains(pattern))
      ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
      ..limit(limit);

    if (channelId != null) {
      q.where((m) => m.channelId.equals(channelId));
    }
    if (conversationId != null) {
      q.where((m) => m.conversationId.equals(conversationId));
    }

    return q.get();
  }

  /// Search contacts by name or pubkey
  Future<List<Contact>> searchContacts(String query, {int limit = 20}) async {
    if (query.trim().isEmpty) return [];
    final pattern = '%${_escapeLike(query)}%';
    return (_db.select(_db.contacts)
          ..where((c) =>
              c.displayName.contains(pattern) |
              c.username.contains(pattern) |
              c.pubkey.contains(pattern))
          ..limit(limit))
        .get();
  }

  String _escapeLike(String s) => s.replaceAll('%', '\\%').replaceAll('_', '\\_');
}
