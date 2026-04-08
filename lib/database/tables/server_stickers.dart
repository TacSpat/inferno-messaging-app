import 'package:drift/drift.dart';

class ServerStickers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get serverId => integer()();
  TextColumn get name => text().withLength(max: 50)();
  TextColumn get description => text().nullable()();
  IntColumn get creatorId => integer()();
  TextColumn get creatorPubkey => text().nullable()();
  TextColumn get url => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {serverId, name},
  ];
}
