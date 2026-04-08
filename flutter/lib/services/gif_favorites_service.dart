import 'dart:math';
import 'package:drift/drift.dart';
import '../database/database.dart';

/// Manages GIF collections and favorites (local DB storage).
/// Mirrors Rails GifCollection + GifFavorite models.
class GifFavoritesService {
  final InfernoDatabase _db;
  final int _userId;

  GifFavoritesService(this._db, this._userId);

  // ─── Collections ──────────────────────────────────────

  /// Get or create the default "Favorites" collection.
  Future<GifCollection> getDefaultCollection() async {
    final existing = await (_db.select(_db.gifCollections)
          ..where((c) => c.userId.equals(_userId) & c.name.equals('Favorites')))
        .getSingleOrNull();
    if (existing != null) return existing;

    final id = await _db.into(_db.gifCollections).insert(GifCollectionsCompanion.insert(
      publicId: _randomId(),
      userId: _userId,
      name: 'Favorites',
      position: Value(0),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
    return (_db.select(_db.gifCollections)..where((c) => c.id.equals(id))).getSingle();
  }

  /// List all collections for this user, ordered by position.
  Stream<List<GifCollection>> watchCollections() {
    return (_db.select(_db.gifCollections)
          ..where((c) => c.userId.equals(_userId))
          ..orderBy([(c) => OrderingTerm.asc(c.position)]))
        .watch();
  }

  /// Get favorite count for a collection.
  Future<int> getFavoritesCount(int collectionId) async {
    final count = _db.gifFavorites.id.count();
    final query = _db.selectOnly(_db.gifFavorites)
      ..addColumns([count])
      ..where(_db.gifFavorites.gifCollectionId.equals(collectionId));
    final result = await query.getSingle();
    return result.read(count) ?? 0;
  }

  /// Create a new collection (max 20 per user, name 1-50 chars).
  Future<GifCollection> createCollection(String name, {String? icon}) async {
    if (name.isEmpty || name.length > 50) throw ArgumentError('Collection name must be 1-50 characters');
    final count = _db.gifCollections.id.count();
    final countQuery = _db.selectOnly(_db.gifCollections)
      ..addColumns([count])
      ..where(_db.gifCollections.userId.equals(_userId));
    final countResult = await countQuery.getSingle();
    if ((countResult.read(count) ?? 0) >= 20) throw StateError('Maximum 20 collections allowed');

    final maxPos = await _maxCollectionPosition();
    final id = await _db.into(_db.gifCollections).insert(GifCollectionsCompanion.insert(
      publicId: _randomId(),
      userId: _userId,
      name: name,
      icon: Value(icon),
      position: Value(maxPos + 1),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
    return (_db.select(_db.gifCollections)..where((c) => c.id.equals(id))).getSingle();
  }

  /// Delete a collection; moves its favorites to default.
  Future<void> deleteCollection(int collectionId) async {
    final defaultCol = await getDefaultCollection();
    if (collectionId == defaultCol.id) return; // can't delete default

    // Move favorites to default (skip duplicates)
    final existingIds = (await (_db.select(_db.gifFavorites)
              ..where((f) => f.gifCollectionId.equals(defaultCol.id)))
            .get())
        .map((f) => f.tenorGifId)
        .toSet();

    final toMove = await (_db.select(_db.gifFavorites)
          ..where((f) => f.gifCollectionId.equals(collectionId)))
        .get();

    for (final fav in toMove) {
      if (existingIds.contains(fav.tenorGifId)) {
        await (_db.delete(_db.gifFavorites)..where((f) => f.id.equals(fav.id))).go();
      } else {
        await (_db.update(_db.gifFavorites)..where((f) => f.id.equals(fav.id)))
            .write(GifFavoritesCompanion(gifCollectionId: Value(defaultCol.id)));
      }
    }

    await (_db.delete(_db.gifCollections)..where((c) => c.id.equals(collectionId))).go();
  }

  // ─── Favorites ────────────────────────────────────────

  /// Watch favorites for a specific collection.
  Stream<List<GifFavorite>> watchFavorites(int collectionId) {
    return (_db.select(_db.gifFavorites)
          ..where((f) => f.gifCollectionId.equals(collectionId))
          ..orderBy([(f) => OrderingTerm.desc(f.position)]))
        .watch();
  }

  /// Get all favorited tenor IDs (across all collections) for quick lookup.
  Future<Set<String>> getAllFavoriteTenorIds() async {
    final all = await (_db.select(_db.gifFavorites)
          ..where((f) => f.userId.equals(_userId)))
        .get();
    return all.map((f) => f.tenorGifId).toSet();
  }

  /// Toggle a GIF in the default Favorites collection.
  /// Returns true if now favorited, false if removed.
  Future<bool> toggleFavorite({
    required String tenorGifId,
    required String tenorUrl,
    required String previewUrl,
    required String gifUrl,
    String? description,
  }) async {
    final defaultCol = await getDefaultCollection();

    final existing = await (_db.select(_db.gifFavorites)
          ..where((f) =>
              f.userId.equals(_userId) &
              f.gifCollectionId.equals(defaultCol.id) &
              f.tenorGifId.equals(tenorGifId)))
        .getSingleOrNull();

    if (existing != null) {
      await (_db.delete(_db.gifFavorites)..where((f) => f.id.equals(existing.id))).go();
      return false;
    }

    final maxPos = await _maxFavoritePosition(defaultCol.id);
    await _db.into(_db.gifFavorites).insert(GifFavoritesCompanion.insert(
      publicId: _randomId(),
      userId: _userId,
      gifCollectionId: defaultCol.id,
      tenorGifId: tenorGifId,
      tenorUrl: tenorUrl,
      previewUrl: previewUrl,
      gifUrl: gifUrl,
      description: Value(description),
      position: Value(maxPos + 1),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
    return true;
  }

  /// Remove a specific favorite by ID.
  Future<void> removeFavorite(int favoriteId) async {
    await (_db.delete(_db.gifFavorites)..where((f) => f.id.equals(favoriteId))).go();
  }

  /// Add a GIF to a specific collection (skip if already exists).
  Future<void> addToCollection({
    required int collectionId,
    required String tenorGifId,
    required String tenorUrl,
    required String previewUrl,
    required String gifUrl,
    String? description,
  }) async {
    final existing = await (_db.select(_db.gifFavorites)
          ..where((f) =>
              f.userId.equals(_userId) &
              f.gifCollectionId.equals(collectionId) &
              f.tenorGifId.equals(tenorGifId)))
        .getSingleOrNull();
    if (existing != null) return;

    final maxPos = await _maxFavoritePosition(collectionId);
    await _db.into(_db.gifFavorites).insert(GifFavoritesCompanion.insert(
      publicId: _randomId(),
      userId: _userId,
      gifCollectionId: collectionId,
      tenorGifId: tenorGifId,
      tenorUrl: tenorUrl,
      previewUrl: previewUrl,
      gifUrl: gifUrl,
      description: Value(description),
      position: Value(maxPos + 1),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
  }

  /// Get collection IDs that contain a specific GIF for this user.
  Future<Set<int>> getCollectionIdsContainingGif(String tenorGifId) async {
    final favs = await (_db.select(_db.gifFavorites)
          ..where((f) =>
              f.userId.equals(_userId) &
              f.tenorGifId.equals(tenorGifId)))
        .get();
    return favs.map((f) => f.gifCollectionId).toSet();
  }

  /// Get favorited tenor IDs in default Favorites collection only.
  Future<Set<String>> getDefaultFavoriteTenorIds() async {
    final defaultCol = await getDefaultCollection();
    final favs = await (_db.select(_db.gifFavorites)
          ..where((f) =>
              f.userId.equals(_userId) &
              f.gifCollectionId.equals(defaultCol.id)))
        .get();
    return favs.map((f) => f.tenorGifId).toSet();
  }

  /// Find a favorite in the default collection by gifUrl.
  Future<GifFavorite?> getFavoriteInDefaultByGifUrl(String gifUrl) async {
    final defaultCol = await getDefaultCollection();
    return await (_db.select(_db.gifFavorites)
          ..where((f) =>
              f.userId.equals(_userId) &
              f.gifCollectionId.equals(defaultCol.id) &
              f.gifUrl.equals(gifUrl)))
        .getSingleOrNull();
  }

  /// Watch favorite count for a collection (live updates).
  Stream<int> watchFavoritesCount(int collectionId) {
    final count = _db.gifFavorites.id.count();
    final query = _db.selectOnly(_db.gifFavorites)
      ..addColumns([count])
      ..where(_db.gifFavorites.gifCollectionId.equals(collectionId));
    return query.watchSingle().map((row) => row.read(count) ?? 0);
  }

  // ─── Helpers ──────────────────────────────────────────

  Future<int> _maxCollectionPosition() async {
    final query = _db.selectOnly(_db.gifCollections)
      ..addColumns([_db.gifCollections.position.max()])
      ..where(_db.gifCollections.userId.equals(_userId));
    final result = await query.getSingle();
    return result.read(_db.gifCollections.position.max()) ?? 0;
  }

  Future<int> _maxFavoritePosition(int collectionId) async {
    final query = _db.selectOnly(_db.gifFavorites)
      ..addColumns([_db.gifFavorites.position.max()])
      ..where(_db.gifFavorites.gifCollectionId.equals(collectionId));
    final result = await query.getSingle();
    return result.read(_db.gifFavorites.position.max()) ?? 0;
  }

  static String _randomId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final r = Random();
    return List.generate(12, (_) => chars[r.nextInt(chars.length)]).join();
  }
}
