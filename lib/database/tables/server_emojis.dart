import 'package:drift/drift.dart';

class ServerEmojis extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get publicId => text().withLength(max: 12).unique()();
  IntColumn get serverId => integer()();
  TextColumn get name => text().withLength(max: 32)();
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
