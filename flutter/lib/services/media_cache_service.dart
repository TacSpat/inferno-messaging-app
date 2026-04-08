import 'dart:ui';
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../database/database.dart';
import '../providers/database_provider.dart';

/// Provides fast sync lookups of cached media dimensions, backed by DB
/// for persistence across restarts.
class MediaCacheService {
  final InfernoDatabase _db;
  final Map<String, Size> _mem = {};
  bool _loaded = false;

  MediaCacheService(this._db);

  /// Load all cached dimensions from DB into memory (call once at startup)
  Future<void> warmUp() async {
    if (_loaded) return;
    try {
      final rows = await _db.select(_db.mediaCache).get();
      for (final row in rows) {
        _mem[row.url] = Size(row.width, row.height);
      }
    } catch (_) {} // Table may not exist yet before migration
    _loaded = true;
  }

  /// Get cached dimensions synchronously (returns null if unknown)
  Size? get(String url) => _mem[url];

  /// Store dimensions in memory + DB
  void put(String url, double width, double height) {
    final size = Size(width, height);
    if (_mem[url] == size) return; // no change
    _mem[url] = size;
    // Fire-and-forget DB write (check-then-insert to avoid PK conflict)
    _persistToDb(url, width, height);
  }

  Future<void> _persistToDb(String url, double width, double height) async {
    try {
      final existing = await (_db.select(_db.mediaCache)
            ..where((m) => m.url.equals(url)))
          .getSingleOrNull();
      if (existing != null) {
        await (_db.update(_db.mediaCache)..where((m) => m.url.equals(url)))
            .write(MediaCacheCompanion(width: Value(width), height: Value(height)));
      } else {
        await _db.into(_db.mediaCache).insert(
          MediaCacheCompanion.insert(url: url, width: width, height: height, createdAt: DateTime.now()),
        );
      }
    } catch (_) {}
  }
}

final mediaCacheServiceProvider = Provider<MediaCacheService>((ref) {
  final db = ref.watch(databaseProvider);
  return MediaCacheService(db);
});
