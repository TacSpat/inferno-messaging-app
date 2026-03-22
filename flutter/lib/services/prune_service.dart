import 'package:drift/drift.dart';
import '../database/database.dart';

class PruneService {
  final InfernoDatabase _db;

  PruneService(this._db);

  /// Run pruning based on current app settings
  Future<PruneResult> runPrune() async {
    final settings = await _db.select(_db.appSettings).getSingleOrNull();
    if (settings == null) return PruneResult(strategy: 'none', messagesDeleted: 0, attachmentsPurged: 0);

    switch (settings.pruningStrategy) {
      case 'time_based':
        return _pruneTimeBased(settings);
      case 'storage_based':
        return _pruneStorageBased(settings);
      default:
        return PruneResult(strategy: 'none', messagesDeleted: 0, attachmentsPurged: 0);
    }
  }

  /// Time-based: delete messages older than retention days
  Future<PruneResult> _pruneTimeBased(AppSetting settings) async {
    if (settings.messageRetentionDays <= 0) {
      return PruneResult(strategy: 'time_based', messagesDeleted: 0, attachmentsPurged: 0);
    }

    final cutoff = DateTime.now().subtract(Duration(days: settings.messageRetentionDays));
    int deleted = 0;

    // Build delete query with protections
    var query = _db.delete(_db.messages)
      ..where((m) => m.createdAt.isSmallerThanValue(cutoff));

    // Protect hidden messages (moderation evidence)
    query = query..where((m) => m.hiddenAt.isNull());

    // Optionally protect pinned messages
    if (settings.keepPinnedMessages) {
      query = query..where((m) => m.pinned.isNull() | m.pinned.equals(false));
    }

    // Scope: channel messages, DMs, or both
    if (!settings.pruneChannelMessages) {
      query = query..where((m) => m.channelId.isNull());
    }
    if (!settings.pruneDmMessages) {
      query = query..where((m) => m.conversationId.isNull());
    }

    deleted = await query.go();
    return PruneResult(strategy: 'time_based', messagesDeleted: deleted, attachmentsPurged: 0);
  }

  /// Storage-based: cascading prune — attachments first, then messages by time, then by DB size
  Future<PruneResult> _pruneStorageBased(AppSetting settings) async {
    int messagesDeleted = 0;
    int attachmentsPurged = 0;

    // Step 1: Purge attachments older than attachment_retention_days
    if (settings.attachmentRetentionDays > 0) {
      final attachCutoff = DateTime.now().subtract(Duration(days: settings.attachmentRetentionDays));
      final oldMessages = await (_db.select(_db.messages)
            ..where((m) => m.createdAt.isSmallerThanValue(attachCutoff) &
                m.fileUrls.isNotNull() &
                m.hiddenAt.isNull()))
          .get();

      for (final msg in oldMessages) {
        if (settings.keepPinnedMessages && msg.pinned == true) continue;
        await (_db.update(_db.messages)..where((m) => m.id.equals(msg.id)))
            .write(const MessagesCompanion(fileUrls: Value(null)));
        attachmentsPurged++;
      }
    }

    // Step 2: Delete old messages by time
    if (settings.messageRetentionDays > 0) {
      final result = await _pruneTimeBased(settings);
      messagesDeleted += result.messagesDeleted;
    }

    // Step 3: If DB still exceeds max size, evict oldest messages in batches
    if (settings.maxDbSizeMb > 0) {
      final dbSize = await _getDbSizeBytes();
      final maxBytes = settings.maxDbSizeMb * 1024 * 1024;

      if (dbSize > maxBytes) {
        // Delete oldest messages in batches of 500
        while (true) {
          final currentSize = await _getDbSizeBytes();
          if (currentSize <= maxBytes) break;

          final oldest = await (_db.select(_db.messages)
                ..where((m) => m.hiddenAt.isNull())
                ..orderBy([(m) => OrderingTerm.asc(m.createdAt)])
                ..limit(500))
              .get();
          if (oldest.isEmpty) break;

          for (final msg in oldest) {
            if (settings.keepPinnedMessages && msg.pinned == true) continue;
            await (_db.delete(_db.messages)..where((m) => m.id.equals(msg.id))).go();
            messagesDeleted++;
          }

          // Run incremental vacuum
          await _db.customStatement('PRAGMA incremental_vacuum');
        }
      }
    }

    return PruneResult(
      strategy: 'storage_based',
      messagesDeleted: messagesDeleted,
      attachmentsPurged: attachmentsPurged,
    );
  }

  /// Get database file size in bytes
  Future<int> _getDbSizeBytes() async {
    try {
      final result = await _db.customSelect('PRAGMA page_count').getSingle();
      final pageCount = result.data.values.first as int;
      final pageSizeResult = await _db.customSelect('PRAGMA page_size').getSingle();
      final pageSize = pageSizeResult.data.values.first as int;
      return pageCount * pageSize;
    } catch (_) {
      return 0;
    }
  }

  /// Get pruning stats for the settings UI
  Future<PruneStats> getStats() async {
    final dbSize = await _getDbSizeBytes();
    final messageCount = await (_db.select(_db.messages)).get().then((m) => m.length);
    final visibleCount = await (_db.select(_db.messages)..where((m) => m.hiddenAt.isNull())).get().then((m) => m.length);

    return PruneStats(
      dbSizeBytes: dbSize,
      totalMessages: messageCount,
      visibleMessages: visibleCount,
    );
  }
}

class PruneResult {
  final String strategy;
  final int messagesDeleted;
  final int attachmentsPurged;
  PruneResult({required this.strategy, required this.messagesDeleted, required this.attachmentsPurged});
}

class PruneStats {
  final int dbSizeBytes;
  final int totalMessages;
  final int visibleMessages;
  PruneStats({required this.dbSizeBytes, required this.totalMessages, required this.visibleMessages});

  String get dbSizeFormatted {
    if (dbSizeBytes < 1024 * 1024) return '${(dbSizeBytes / 1024).toStringAsFixed(1)} KB';
    if (dbSizeBytes < 1024 * 1024 * 1024) return '${(dbSizeBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(dbSizeBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
