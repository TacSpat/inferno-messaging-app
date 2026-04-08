import 'package:drift/drift.dart';
import '../database/database.dart';

class SearchFilter {
  final List<String> fromPubkeys;
  final List<String> hasTypes; // 'file', 'image', 'link'
  final List<int> inChannelIds; // empty = current channel only
  final DateTime? before;
  final DateTime? after;
  final DateTime? on;

  const SearchFilter({
    this.fromPubkeys = const [],
    this.hasTypes = const [],
    this.inChannelIds = const [],
    this.before,
    this.after,
    this.on,
  });

  bool get isEmpty =>
      fromPubkeys.isEmpty &&
      hasTypes.isEmpty &&
      inChannelIds.isEmpty &&
      before == null &&
      after == null &&
      on == null;
}

class SearchService {
  final InfernoDatabase _db;

  SearchService(this._db);

  /// Search messages with structured filters matching Rails' apply_search_filters.
  /// When [defaultChannelId] is set and no `in:` filters exist, scopes to that channel.
  Future<List<Message>> searchWithFilters({
    String? query,
    int? defaultChannelId,
    SearchFilter filter = const SearchFilter(),
    int limit = 25,
    int offset = 0,
  }) async {
    if ((query == null || query.trim().isEmpty) && filter.isEmpty && defaultChannelId == null) return [];

    var q = _db.select(_db.messages)
      ..orderBy([(m) => OrderingTerm.desc(m.createdAt)])
      ..limit(limit, offset: offset);

    _applyFilters(q, query: query, defaultChannelId: defaultChannelId, filter: filter);
    return q.get();
  }

  /// Count total matching messages (for pagination display).
  Future<int> countWithFilters({
    String? query,
    int? defaultChannelId,
    SearchFilter filter = const SearchFilter(),
  }) async {
    if ((query == null || query.trim().isEmpty) && filter.isEmpty && defaultChannelId == null) return 0;

    final count = countAll();
    final q = _db.selectOnly(_db.messages)..addColumns([count]);

    // Apply same filters via where clauses
    q.where(_db.messages.systemMessage.equals(false));

    if (filter.inChannelIds.isNotEmpty) {
      q.where(_db.messages.channelId.isIn(filter.inChannelIds));
    } else if (defaultChannelId != null) {
      q.where(_db.messages.channelId.equals(defaultChannelId));
    }

    if (query != null && query.trim().isNotEmpty) {
      final pattern = '%${_escapeLike(query.trim())}%';
      q.where(_db.messages.content.like(pattern));
    }

    if (filter.fromPubkeys.isNotEmpty) {
      q.where(_db.messages.nostrAuthorPubkey.isIn(filter.fromPubkeys));
    }

    if (filter.hasTypes.isNotEmpty) {
      Expression<bool>? expr;
      for (final ht in filter.hasTypes) {
        Expression<bool> sub;
        switch (ht) {
          case 'file':
          case 'image':
            sub = _db.messages.fileUrls.isNotNull() & _db.messages.fileUrls.like('%http%') |
                _db.messages.content.like('%blossom.%');
            break;
          case 'link':
            sub = _db.messages.content.like('%http%');
            break;
          default:
            continue;
        }
        expr = expr == null ? sub : (expr | sub);
      }
      if (expr != null) q.where(expr);
    }

    if (filter.before != null) {
      q.where(_db.messages.createdAt.isSmallerThanValue(filter.before!));
    }
    if (filter.after != null) {
      q.where(_db.messages.createdAt.isBiggerThanValue(filter.after!));
    }
    if (filter.on != null) {
      final start = DateTime(filter.on!.year, filter.on!.month, filter.on!.day);
      final end = start.add(const Duration(days: 1));
      q.where(_db.messages.createdAt.isBiggerOrEqualValue(start) &
          _db.messages.createdAt.isSmallerThanValue(end));
    }

    final result = await q.getSingle();
    return result.read(count) ?? 0;
  }

  void _applyFilters(SimpleSelectStatement<$MessagesTable, Message> q, {
    String? query,
    int? defaultChannelId,
    SearchFilter filter = const SearchFilter(),
  }) {
    q.where((m) => m.systemMessage.equals(false));

    if (filter.inChannelIds.isNotEmpty) {
      q.where((m) => m.channelId.isIn(filter.inChannelIds));
    } else if (defaultChannelId != null) {
      q.where((m) => m.channelId.equals(defaultChannelId));
    }

    if (query != null && query.trim().isNotEmpty) {
      final pattern = '%${_escapeLike(query.trim())}%';
      q.where((m) => m.content.like(pattern));
    }

    if (filter.fromPubkeys.isNotEmpty) {
      q.where((m) => m.nostrAuthorPubkey.isIn(filter.fromPubkeys));
    }

    if (filter.hasTypes.isNotEmpty) {
      q.where((m) {
        Expression<bool>? expr;
        for (final ht in filter.hasTypes) {
          Expression<bool> sub;
          switch (ht) {
            case 'file':
            case 'image':
              sub = m.fileUrls.isNotNull() & m.fileUrls.like('%http%') |
                  m.content.like('%blossom.%');
              break;
            case 'link':
              sub = m.content.like('%http%');
              break;
            default:
              continue;
          }
          expr = expr == null ? sub : (expr | sub);
        }
        return expr ?? const Constant(true);
      });
    }

    if (filter.before != null) {
      q.where((m) => m.createdAt.isSmallerThanValue(filter.before!));
    }
    if (filter.after != null) {
      q.where((m) => m.createdAt.isBiggerThanValue(filter.after!));
    }
    if (filter.on != null) {
      final start = DateTime(filter.on!.year, filter.on!.month, filter.on!.day);
      final end = start.add(const Duration(days: 1));
      q.where((m) =>
          m.createdAt.isBiggerOrEqualValue(start) &
          m.createdAt.isSmallerThanValue(end));
    }
  }

  /// Search members of a server by name/username for the "from:" autocomplete.
  /// Returns all members when query is empty.
  Future<List<RemoteMember>> searchMembers(int serverId, String query, {int limit = 10}) async {
    if (query.trim().isEmpty) {
      return (_db.select(_db.remoteMembers)
            ..where((m) => m.serverId.equals(serverId))
            ..orderBy([(m) => OrderingTerm.asc(m.displayName)])
            ..limit(limit))
          .get();
    }
    final pattern = '%${_escapeLike(query.trim())}%';
    return (_db.select(_db.remoteMembers)
          ..where((m) =>
              m.serverId.equals(serverId) &
              (m.displayName.like(pattern) | m.username.like(pattern)))
          ..limit(limit))
        .get();
  }

  /// Search channels of a server by name for the "in:" autocomplete
  Future<List<Channel>> searchChannels(int serverId, String query, {int limit = 8}) async {
    if (query.trim().isEmpty) {
      // Return all text channels when query is empty
      return (_db.select(_db.channels)
            ..where((c) => c.serverId.equals(serverId) & c.channelType.equals(0))
            ..orderBy([(c) => OrderingTerm.asc(c.position)])
            ..limit(limit))
          .get();
    }
    final pattern = '%${_escapeLike(query.trim())}%';
    return (_db.select(_db.channels)
          ..where((c) =>
              c.serverId.equals(serverId) &
              c.channelType.equals(0) &
              c.name.like(pattern))
          ..orderBy([(c) => OrderingTerm.asc(c.position)])
          ..limit(limit))
        .get();
  }

  /// Get all text channel IDs for a server
  Future<List<int>> getServerChannelIds(int serverId) async {
    final channels = await (_db.select(_db.channels)
          ..where((c) => c.serverId.equals(serverId) & c.channelType.equals(0)))
        .get();
    return channels.map((c) => c.id).toList();
  }

  String _escapeLike(String s) => s.replaceAll('%', '\\%').replaceAll('_', '\\_');
}
