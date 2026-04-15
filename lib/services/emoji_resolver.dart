import 'package:drift/drift.dart';
import '../database/database.dart';

/// Resolves `:shortcode:` emoji names to URLs from local sources,
/// and caches seen emoji (name, url) pairs persistently so references
/// remain resolvable after the user leaves a server or the server deletes
/// the emoji.
class EmojiResolver {
  final InfernoDatabase _db;

  EmojiResolver(this._db);

  static final _shortcodePattern = RegExp(r':([a-zA-Z0-9_]+):');

  /// Extract all unique :shortcode: names from [content].
  static Set<String> extractNames(String content) {
    final names = <String>{};
    for (final match in _shortcodePattern.allMatches(content)) {
      names.add(match.group(1)!);
    }
    return names;
  }

  /// Resolve a set of emoji names to a {name: url} map.
  /// Checks server_emojis first (all servers), then the persistent emoji_cache.
  Future<Map<String, String>> resolveNames(Set<String> names) async {
    if (names.isEmpty) return const {};
    final out = <String, String>{};

    final serverRows = await (_db.select(_db.serverEmojis)
          ..where((e) => e.name.isIn(names)))
        .get();
    for (final e in serverRows) {
      if (e.url != null && !out.containsKey(e.name)) {
        out[e.name] = e.url!;
      }
    }

    final remaining = names.difference(out.keys.toSet());
    if (remaining.isNotEmpty) {
      final cacheRows = await (_db.select(_db.emojiCache)
            ..where((c) => c.name.isIn(remaining)))
          .get();
      for (final c in cacheRows) {
        if (!out.containsKey(c.name)) out[c.name] = c.url;
      }
    }

    return out;
  }

  /// Scan [content] and produce a {name: url} map of every shortcode
  /// that currently resolves. Used when publishing a message to attach
  /// NIP-30 emoji tags and persist URLs on the message row.
  Future<Map<String, String>> resolveInContent(String content) async {
    return resolveNames(extractNames(content));
  }

  /// Cache every (name, url) pair for future lookups. Idempotent.
  Future<void> cacheAll(Map<String, String> emojis) async {
    if (emojis.isEmpty) return;
    final now = DateTime.now();
    await _db.batch((batch) {
      for (final entry in emojis.entries) {
        if (entry.key.isEmpty || entry.value.isEmpty) continue;
        batch.insert(
          _db.emojiCache,
          EmojiCacheCompanion.insert(
            name: entry.key,
            url: entry.value,
            lastSeenAt: now,
          ),
          mode: InsertMode.insertOrIgnore,
        );
      }
    });
  }
}
