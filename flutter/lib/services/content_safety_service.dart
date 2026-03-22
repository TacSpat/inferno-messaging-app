import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../database/database.dart';

class ContentSafetyService {
  final InfernoDatabase _db;

  ContentSafetyService(this._db);

  /// Check if a file's SHA-256 hash matches any known-bad hashes
  Future<bool> isHashBlocked(Uint8List fileBytes) async {
    final hash = sha256.convert(fileBytes).toString();
    final match = await (_db.select(_db.contentHashes)
          ..where((c) => c.hashValue.equals(hash) & c.allowlisted.equals(false)))
        .getSingleOrNull();
    return match != null;
  }

  /// Check message content against keyword filter
  Future<bool> containsBlockedKeywords(String content, String keywordFilter) async {
    if (keywordFilter.isEmpty) return false;
    final keywords = keywordFilter.split(',').map((k) => k.trim().toLowerCase()).where((k) => k.isNotEmpty);
    final lower = content.toLowerCase();
    for (final keyword in keywords) {
      if (lower.contains(keyword)) return true;
    }
    return false;
  }

  /// Store a content hash for future matching
  Future<void> recordHash({
    required String hashValue,
    required String hashType,
    int? messageId,
    String? mediaType,
    String source = 'local',
  }) async {
    await _db.into(_db.contentHashes).insert(ContentHashesCompanion.insert(
      hashValue: hashValue,
      hashType: Value(hashType),
      messageId: Value(messageId),
      mediaType: Value(mediaType),
      source: Value(source),
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
  }

  /// Check if content should be blurred (NSFW)
  bool shouldBlurContent(bool safetyBlurNsfw, bool isNsfw) {
    return safetyBlurNsfw && isNsfw;
  }
}
