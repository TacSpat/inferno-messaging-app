import 'package:drift/drift.dart';

/// Persistent cache of custom emoji name -> URL mappings.
/// Populated from:
///  - Server emoji events (Kind 31754)
///  - NIP-30 emoji tags seen on incoming messages
/// Survives leaving servers and server-side deletion, so emoji references in
/// old messages stay resolvable.
class EmojiCache extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get url => text()();
  DateTimeColumn get lastSeenAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
        {name, url},
      ];
}
